const req = require('../../util/req.js');

let url = 'http://api.maiyoux.com:81/mf/';
let cateList = {};

async function request(reqUrl) {
    let res = await req(reqUrl, { method: 'get' });
    return res.data;
}

async function init(inReq, _outResp) {
    cateList = await request(url + 'json.txt');
    return cateList;
}

async function home(_inReq, _outResp) {
    let classes = [];
    Object.keys(cateList).forEach(function(key) {
        classes.push({ type_id: key, type_name: key });
    });
    return { class: classes };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    const pg = inReq.body.page || 1;
    let videos = [];
    for (const item of (cateList[tid] || [])) {
        videos.push({
            vod_id: item['address'],
            vod_name: item['title'],
            vod_pic: item['xinimg'],
            vod_remarks: item['Number']
        });
    }
    return { list: videos, page: pg, pagecount: 1, total: videos.length };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const res = await request(url + ids[0]);
    const video = { vod_play_from: 'Leospring', vod_content: '作者：Leospring 公众号：蚂蚁科技杂谈' };
    let playNameUrls = [];
    for (const item of (res['zhubo'] || [])) {
        playNameUrls.push(item.title + '$' + item.address);
    }
    video.vod_play_url = playNameUrls.join('#');
    return { list: [video] };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    return { parse: 0, url: id };
}

async function search(inReq, _outResp) {
    return {};
}

module.exports = {
    meta: { key: 'maiyoux', name: 'maiyoux', type: 3 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
