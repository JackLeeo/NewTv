const req = require('../../util/req.js');
const _ = require('lodash');
const CryptoJS = require('crypto-js');

let host = 'http://op.ysdqjs.cn';
let parseMap = {};
let cookie = '';

const UA = 'okhttp-okgo/jeasonlzy';

async function request(reqUrl, method, data) {
    const headers = { 'User-Agent': UA };
    if (!_.isEmpty(cookie)) {
        headers['Cookie'] = cookie;
    }
    const postType = method === 'post' ? 'form-data' : '';
    let res = await req(reqUrl, {
        method: method || 'get',
        headers: headers,
        data: data,
        postType: postType,
    });
    if (res.code == 403) {
        const path = res.data.match(/window\.location\.href ="(.*?)"/)[1];
        const setCookie = _.isArray(res.headers['set-cookie']) ? res.headers['set-cookie'].join(';') : res.headers['set-cookie'];
        cookie = setCookie;
        headers['Cookie'] = cookie;
        res = await req(host + path, { method: method || 'get', headers: headers, data: data, postType: postType });
    }
    return res.data;
}

async function init(inReq, _outResp) {
    return {};
}

async function home(filter) {
    const json = await postData(host + '/v2/type/top_type');
    const classes = _.map(json.data.list, (item) => ({ type_id: item.type_id, type_name: item.type_name }));
    const filterConfig = {};
    _.each(json.data.list, (item) => {
        const extend = convertTypeData(item, 'extend', '剧情');
        const area = convertTypeData(item, 'area', '地区');
        const lang = convertTypeData(item, 'lang', '语言');
        const year = convertTypeData(item, 'year', '年份');
        const filterArray = [extend, area, lang, year].filter((type) => type !== null);
        filterConfig[item.type_id] = filterArray;
    });
    return { class: classes, filters: filterConfig };
}

async function postData(url, data) {
    const timestamp = Math.floor(new Date().getTime() / 1000);
    const key = 'kj5649ertj84ks89r4jh8s45hf84hjfds04k';
    const sign = CryptoJS.MD5(key + timestamp).toString();
    let defaultData = { sign: sign, timestamp: timestamp };
    const reqData = data ? _.merge(defaultData, data) : defaultData;
    return await request(url, 'post', reqData);
}

function convertTypeData(typeData, key, name) {
    if (!typeData || !typeData[key] || typeData[key].length <= 2) return null;
    return {
        key: key == 'extend' ? 'class' : key,
        name: name,
        init: '',
        value: _.map(typeData[key], (item) => ({ n: item, v: item == '全部' ? '' : item })),
    };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    let pg = inReq.body.page || 1;
    const extend = inReq.body.filters || {};
    const limit = 12;
    const param = { type_id: tid, page: pg, limit: limit };
    if (extend.class) param.class = extend.class;
    if (extend.area) param.area = extend.area;
    if (extend.lang) param.lang = extend.lang;
    if (extend.year) param.year = extend.year;
    const json = await postData(host + '/v2/home/type_search', param);
    const videos = _.map(json.data.list, (vObj) => ({
        vod_id: vObj.vod_id, vod_name: vObj.vod_name,
        vod_pic: vObj.vod_pic || vObj.vod_pic_thumb, vod_remarks: vObj.vod_remarks,
    }));
    return { page: parseInt(pg), pagecount: json.data.list.length >= limit ? parseInt(pg) + 1 : parseInt(pg), limit, total: 0, list: videos };
}

async function detail(inReq, _outResp) {
    const id = inReq.body.id;
    const json = await postData(host + '/v2/home/vod_details', { vod_id: id });
    const vObj = json.data;
    const vodAtom = {
        vod_id: id, vod_name: vObj.vod_name, vod_pic: vObj.vod_pic || vObj.vod_pic_thumb,
        vod_year: vObj.vod_year, vod_area: vObj.vod_area, vod_lang: vObj.vod_lang,
        vod_remarks: vObj.vod_remarks, vod_actor: vObj.vod_actor, vod_director: vObj.vod_director,
        vod_content: vObj.vod_content ? vObj.vod_content.replace(/&[^;]+;/g, ' ').replace(/<[^>]+>/g, '') : '',
    };
    const playVod = {};
    _.each(vObj.vod_play_list || [], (obj) => {
        if (!_.isEmpty(obj.parse_urls)) parseMap[obj.name] = obj.parse_urls;
        const items = _.map(obj.urls, (epObj) => epObj.name + '$' + epObj.url).filter(s => s);
        if (items.length > 0) playVod[obj.name] = items.join('#');
    });
    vodAtom.vod_play_from = _.keys(playVod).join('$$$');
    vodAtom.vod_play_url = _.values(playVod).join('$$$');
    return { list: [vodAtom] };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    const flag = inReq.body.flag;
    let playUrl = id;
    const parsers = parseMap[flag];
    if (!_.isEmpty(parsers)) {
        for (const parser of parsers) {
            if (_.isEmpty(parser)) continue;
            try {
                const resp = await request(parser + playUrl);
                const json = JSON.parse(resp);
                if (!_.isEmpty(json.url)) { playUrl = json.url; break; }
            } catch (e) { /* skip */ }
        }
    }
    return { parse: 0, url: playUrl };
}

async function search(inReq, _outResp) {
    const wd = inReq.body.wd;
    let pg = inReq.body.page || 1;
    const json = await postData(host + '/v2/home/search', { keyword: wd, page: pg, limit: 12 });
    const videos = _.map(json.data.list, (vObj) => ({
        vod_id: vObj.vod_id, vod_name: vObj.vod_name,
        vod_pic: vObj.vod_pic || vObj.vod_pic_thumb, vod_remarks: vObj.vod_remarks,
    }));
    return { page: parseInt(pg), pagecount: parseInt(pg) + 1, limit: 12, total: 0, list: videos };
}

module.exports = {
    meta: { key: 'ttian', name: '天天影视', type: 3 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
