const req = require('../../util/req.js');
const CryptoJS = require('crypto-js');
const cheerio = require('cheerio');

const siteUrl = 'https://saohuo.us';
let url = 'https://saohuo.tv';

const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1";
let cookie = {};

async function request(reqUrl, referer, data, method = 'get', postType = '') {
    let headers = {
        'User-Agent': UA,
        Referer: referer ? encodeURIComponent(referer) : siteUrl,
        Cookie: Object.keys(cookie)
            .map((key) => `${key}=${cookie[key]}`)
            .join(';'),
    };

    let response = await req(reqUrl, {
        method: method,
        headers: headers,
        data: data,
        postType: postType
    });

    if (response.headers["set-cookie"]) {
        for (const c of (Array.isArray(response.headers["set-cookie"]) ? response.headers["set-cookie"].join(";") : response.headers["set-cookie"]).split(";")) {
            let tmp = c.trim();
            if (tmp.startsWith("result=")) {
                cookie.result = tmp.substring(7);
                return request(reqUrl, reqUrl, data, 'post', { result: cookie.result });
            }
            if (tmp.startsWith("esc_search_captcha=1")) {
                cookie.esc_search_captcha = 1;
                delete cookie.result;
                return request(reqUrl);
            }
        }
    }
    return response.data;
}

async function init(inReq, _outResp) {
    return {};
}

async function home(filter) {
    let classes = [{"type_id":"1","type_name":"电影"},{"type_id":"2","type_name":"电视剧"}];
    let filterObj = {
        1: [{"key": "type_id", "name": "类型", "value": [{"n": "全部", "v": "1"}, {"n": "喜剧", "v": "6"}, {"n": "爱情", "v": "7"}, {"n": "恐怖", "v": "8"}, {"n": "动作", "v": "9"}, {"n": "科幻", "v": "10"}, {"n": "战争", "v": "11"}, {"n": "犯罪", "v": "12"}, {"n": "动画", "v": "13"}, {"n": "奇幻", "v": "14"}, {"n": "剧情", "v": "15"}, {"n": "悬疑", "v": "17"}, {"n": "惊悚", "v": "18"}, {"n": "其他", "v": "19"}]}],
        2: [{"key": "type_id", "name": "类型", "value": [{"n": "全部", "v": "2"}, {"n": "大陆", "v": "20"}, {"n": "TVB", "v": "21"}, {"n": "韩剧", "v": "22"}, {"n": "美剧", "v": "23"}, {"n": "日剧", "v": "24"}, {"n": "英剧", "v": "25"}, {"n": "台剧", "v": "26"}, {"n": "其他", "v": "27"}]}]
    };
    return { class: classes, filters: filterObj };
}

async function category(inReq, _outResp) {
    let tid = inReq.body.id;
    let pg = inReq.body.page;
    if (pg <= 0) pg = 1;
    const reqUrl = `${siteUrl}/list/${tid}-${pg}.html`;
    const html = await request(reqUrl);
    const $ = cheerio.load(html);
    const items = $('.v_list li');
    let videos = [];
    for (let item of items) {
        const vodId = $(item).find('a').attr('href');
        const vodName = $(item).find('a').attr('title');
        const vodPic = $(item).find('a img').attr('data-original');
        const vodRemarks = $(item).find('[class=v_note]').text();
        videos.push({ vod_id: vodId, vod_name: vodName, vod_pic: vodPic, vod_remarks: vodRemarks });
    }
    var hasMore = $('.page a:contains(下一页)').length > 0;
    var pgCount = hasMore ? parseInt(pg) + 1 : parseInt(pg);
    return { page: parseInt(pg), pagecount: pgCount, limit: 24, total: 24 * pgCount, list: videos };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const videos = [];
    for (const id of ids) {
        const html = await request(siteUrl + id);
        const $ = cheerio.load(html);
        let vod = {
            vod_id: id,
            vod_name: $('h1.v_title').text().trim(),
            vod_actor: $('.grid_box:first p').text().trim(),
            vod_content: $('p').text().trim(),
        };
        const playlist = $('ul.large_list li > a')
            .map((_, a) => a.children[0].data + '$' + a.attribs.href.replace(/.*?\/play\/(.*).html/g, '$1'))
            .get();
        vod.vod_play_from = '1号线路';
        vod.vod_play_url = playlist.join('#');
        videos.push(vod);
    }
    return { list: videos };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    const response = await request(`${siteUrl}/play/${id}.html`);
    const $ = cheerio.load(response);
    const rand = response.match(/<iframe src="(.*?)"/);
    if (rand && rand[1]) {
        return JSON.stringify({ parse: 0, url: rand[1] });
    }
    return JSON.stringify({ parse: 0, url: '' });
}

async function search(inReq, _outResp) {
    let pg = inReq.body.page;
    const wd = inReq.body.wd;
    let page = pg || 1;
    if (page == 0) page = 1;
    let searchURL = `${siteUrl}/search.php?searchword=${encodeURIComponent(wd)}`;
    let htmlContent = await request(searchURL);
    const $ = cheerio.load(htmlContent);
    let items = $('.v_list li');
    let results = [];
    items.each((index, element) => {
        let vodId = $(element).find('div a').attr('href');
        let vodName = $(element).find('div a').attr('title');
        let vodPic = $(element).find('div a img').attr('data-original');
        let vodRemarks = $(element).find('.v_note').text();
        results.push({ vod_id: vodId, vod_name: vodName, vod_pic: vodPic, vod_remarks: vodRemarks });
    });
    return { list: results };
}

async function test(inReq, outResp) {
    try {
        const prefix = inReq.server.prefix;
        const dataResult = {};
        let resp = await inReq.server.inject().post(`${prefix}/init`);
        dataResult.init = resp.json();
        resp = await inReq.server.inject().post(`${prefix}/home`);
        dataResult.home = resp.json();
        if (dataResult.home.class && dataResult.home.class.length > 0) {
            resp = await inReq.server.inject().post(`${prefix}/category`).payload({
                id: dataResult.home.class[0].type_id, page: 1, filters: {},
            });
            dataResult.category = resp.json();
        }
        return dataResult;
    } catch (err) {
        return { err: err.message };
    }
}

module.exports = {
    meta: { key: 'saohuo', name: '骚火影视', type: 3 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
        fastify.get('/test', test);
    },
};
