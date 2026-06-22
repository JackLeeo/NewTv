import req from '../../util/req.js';
import { load } from 'cheerio';
import { UA, stripHtmlTag } from '../../util/misc.js';

let url = '';

async function request(reqUrl) {
    const resp = await req.get(reqUrl, {
        headers: {
            'User-Agent': UA,
        },
    });
    return resp.data;
}

async function init(inReq, _outResp) {
    const config = inReq.server.config;
    url = config.kunyu77.testcfg.url || 'https://api.kunyu77.com';
    return {};
}

async function home(_inReq, _outResp) {
    return {
        class: [
            { type_id: 'dianying', type_name: '电影' },
            { type_id: 'lianxuju', type_name: '连续剧' },
            { type_id: 'zongyi', type_name: '综艺' },
            { type_id: 'dongman', type_name: '动漫' },
            { type_id: 'jilupian', type_name: '纪录片' },
            { type_id: 'xiaoshipin', type_name: '短视频' },
        ],
    };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    const pg = inReq.body.page;
    let page = pg || 1;
    if (page == 0) page = 1;
    let reqUrl = `${url}/api.php/provide/vod/?ac=detail&t=${tid}&pg=${page}`;
    let data = await request(reqUrl);
    let videos = [];
    if (data.list) {
        for (const vod of data.list) {
            videos.push({
                vod_id: vod.vod_id,
                vod_name: stripHtmlTag(vod.vod_name),
                vod_pic: vod.vod_pic,
                vod_remarks: vod.vod_remarks || '',
            });
        }
    }
    return {
        page: parseInt(data.page) || page,
        pagecount: parseInt(data.pagecount) || 1,
        total: parseInt(data.total) || videos.length,
        list: videos,
    };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const videos = [];
    for (const id of ids) {
        let reqUrl = `${url}/api.php/provide/vod/?ac=detail&ids=${id}`;
        let data = await request(reqUrl);
        if (data.list && data.list.length > 0) {
            const vod = data.list[0];
            videos.push({
                vod_id: vod.vod_id,
                vod_name: stripHtmlTag(vod.vod_name),
                vod_pic: vod.vod_pic,
                type_name: vod.type_name,
                vod_year: vod.vod_year,
                vod_area: vod.vod_area,
                vod_remarks: vod.vod_remarks || '',
                vod_actor: vod.vod_actor,
                vod_director: vod.vod_director,
                vod_content: stripHtmlTag(vod.vod_content),
                vod_play_from: vod.vod_play_from,
                vod_play_url: vod.vod_play_url,
            });
        }
    }
    return { list: videos };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    if (id.indexOf('.m3u8') < 0) {
        return { parse: 1, url: id };
    }
    return { parse: 0, url: id };
}

async function search(inReq, _outResp) {
    const wd = inReq.body.wd;
    const pg = inReq.body.page || 1;
    let reqUrl = `${url}/api.php/provide/vod/?ac=detail&wd=${encodeURIComponent(wd)}&pg=${pg}`;
    let data = await request(reqUrl);
    let videos = [];
    if (data.list) {
        for (const vod of data.list) {
            videos.push({
                vod_id: vod.vod_id,
                vod_name: stripHtmlTag(vod.vod_name),
                vod_pic: vod.vod_pic,
                vod_remarks: vod.vod_remarks || '',
            });
        }
    }
    return {
        page: parseInt(data.page) || pg,
        pagecount: parseInt(data.pagecount) || 1,
        list: videos,
    };
}

async function test(inReq, outResp) {
    try {
        const printErr = (json) => {
            if (json.statusCode == 500) console.error(json);
        };
        const prefix = inReq.server.prefix;
        let resp = await inReq.server.inject().post(`${prefix}/home`);
        const homeResult = resp.json();
        printErr(homeResult);
        if (homeResult.class.length > 0) {
            resp = await inReq.server.inject().post(`${prefix}/category`).payload({ id: homeResult.class[0].type_id, page: 1 });
            const catResult = resp.json();
            printErr(catResult);
            if (catResult.list.length > 0) {
                resp = await inReq.server.inject().post(`${prefix}/detail`).payload({ id: catResult.list[0].vod_id });
                printErr(resp.json());
            }
        }
        resp = await inReq.server.inject().post(`${prefix}/search`).payload({ wd: '测试', page: 1 });
        printErr(resp.json());
        return { status: 'ok' };
    } catch (err) {
        console.error(err);
        outResp.code(500);
        return { err: err.message };
    }
}

export default {
    meta: { key: 'kunyu77', name: '酷云77', type: 3 },
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
