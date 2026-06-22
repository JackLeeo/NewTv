const req = require('../../util/req.js');
const { randStr } = require('../../util/misc.js');
const dayjs = require('dayjs');
const CryptoJS = require('crypto-js');

let domain = 'https://frodo.douban.com';
let device = {};

function sig(link) {
    link += `&udid=${device.id}&uuid=${device.id}&&rom=android&apikey=0dad551ec0f84ed02907ff5c42e8ec70&s=rexxar_new&channel=Yingyongbao_Market&timezone=Asia/Shanghai&device_id=${device.id}&os_rom=android&apple=c52fbb99b908be4d026954cc4374f16d&mooncake=0f607264fc6318a92b9e13c65db7cd3c&sugar=0`;
    const u = new URL(link);
    const ts = dayjs().unix().toString();
    let sha1 = CryptoJS.HmacSHA1('GET&' + encodeURIComponent(u.pathname) + '&' + ts, 'bf7dddc7c9cfe6f7');
    let signa = CryptoJS.enc.Base64.stringify(sha1);
    return link + '&_sig=' + encodeURIComponent(signa) + '&_ts=' + ts;
}

async function request(reqUrl, ua) {
    const resp = await req.get(reqUrl, {
        headers: { 'User-Agent': ua || device.ua },
    });
    return resp.data;
}

async function init(inReq, _outResp) {
    const deviceKey = inReq.server.prefix + '/device';
    device = await inReq.server.db.getObjectDefault(deviceKey, {});
    if (!device.id) {
        device.id = randStr(40).toLowerCase();
        device.ua = `Rexxar-Core/0.1.3 api-client/1 com.douban.frodo/7.9.0(216) Android/28 product/Xiaomi11 rom/android network/wifi udid/${device.id} platform/mobile com.douban.frodo/7.9.0(216) Rexxar/1.2.151 platform/mobile 1.2.151`;
        await inReq.server.db.push(deviceKey, device);
    }
    return {};
}

async function home(_inReq, _outResp) {
    const link = sig(domain + '/api/v2/movie/tag?sort=U&start=0&count=30&q=全部形式,全部类型,全部地区,全部年代&score_rang=0,10');
    const data = await request(link);
    let classes = [
        { type_id: 't1', type_name: '热播' },
        { type_id: 't2', type_name: '片库' },
        { type_id: 't250', type_name: 'Top250' },
        { type_id: 't3', type_name: '榜单', ratio: 1 },
        { type_id: 't4', type_name: '片单', ratio: 1 },
    ];
    let filterObj = {};
    filterObj['t1'] = [
        { key: 'u', name: '', init: 'movie/hot_gaia', value: [
            { n: '电影', v: 'movie/hot_gaia' },
            { n: '电视剧', v: 'subject_collection/tv_hot/items' },
            { n: '国产剧', v: 'subject_collection/tv_domestic/items' },
            { n: '美剧', v: 'subject_collection/tv_american/items' },
            { n: '日剧', v: 'subject_collection/tv_japanese/items' },
            { n: '韩剧', v: 'subject_collection/tv_korean/items' },
            { n: '动漫', v: 'subject_collection/tv_animation/items' },
            { n: '综艺', v: 'subject_collection/show_hot/items' },
        ]},
    ];
    filterObj['t4'] = [
        { key: 'type', name: '', init: '', value: [
            { n: '全部', v: '' }, { n: '电影', v: 'movie' }, { n: '电视剧', v: 'tv' },
        ]},
    ];
    let filterAll = [];
    for (const tag of data.tags || []) {
        if (tag.type == '特色') continue;
        let f = { key: tag.type, name: '', init: tag.data[0] || '' };
        let fValues = [];
        if (tag.type == '年代' && tag.data.indexOf(dayjs().year().toString()) < 0) {
            tag.data.splice(1, 0, dayjs().year().toString());
        }
        for (const v of tag.data) {
            let n = v;
            if (v.indexOf('全部') >= 0) n = '全部';
            fValues.push({ n: n, v: v });
        }
        f.value = fValues;
        filterAll.push(f);
    }
    filterObj['t2'] = filterAll;
    return { class: classes, filters: filterObj };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    const pg = inReq.body.page || 1;
    const extend = inReq.body.filters || {};
    if (tid == 't1') {
        const link = sig(`${domain}/api/v2/${extend.u || 'movie/hot_gaia'}?area=全部&sort=recommend&playable=0&loc_id=0&start=${(pg - 1) * 30}&count=30`);
        const data = await request(link);
        let videos = [];
        for (const vod of data.items || data.subject_collection_items || []) {
            let score = vod.rating ? (vod.rating.value || '') : '';
            videos.push({
                vod_id: vod.id, vod_name: vod.title,
                vod_pic: vod.pic.normal || vod.pic.large,
                vod_remarks: score.toString().length > 0 ? '评分:' + score : '',
            });
        }
        return { page: parseInt(pg), pagecount: Math.ceil((data.total || 0) / 30), list: videos };
    } else if (tid == 't250') {
        const link = sig(`${domain}/api/v2/subject_collection/movie_top250/items?start=${(pg - 1) * 30}&count=30`);
        const data = await request(link);
        let videos = [];
        for (const vod of data.items || data.subject_collection_items || []) {
            let score = vod.rating ? (vod.rating.value || '') : '';
            videos.push({
                vod_id: vod.id, vod_name: vod.title,
                vod_pic: vod.pic.normal || vod.pic.large,
                vod_remarks: score.toString().length > 0 ? '评分:' + score : '',
            });
        }
        return { page: parseInt(pg), pagecount: Math.ceil((data.total || 0) / 30), list: videos };
    }
    return { page: 1, pagecount: 1, list: [] };
}

async function detail(_inReq, _outResp) {
    return { list: [] };
}

async function play(_inReq, _outResp) {
    return {};
}

async function search(_inReq, _outResp) {
    return {};
}

module.exports = {
    meta: { key: 'douban', name: '豆瓣电影', type: 3, indexs: 1 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
