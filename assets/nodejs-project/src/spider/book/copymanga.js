import req from '../../util/req.js';
import CryptoJS from 'crypto-js';
import { UA, randUUID } from '../../util/misc.js';

let url = '';

async function init(inReq, _outResp) {
    url = inReq.server.config.copymanga?.url || 'https://www.copymanga.info';
    return {};
}

async function home(_inReq, _outResp) {
    return {
        class: [
            { type_id: '全部', type_name: '全部' },
            { type_id: '冒险', type_name: '冒险' },
            { type_id: '搞笑', type_name: '搞笑' },
            { type_id: '恋爱', type_name: '恋爱' },
            { type_id: '格斗', type_name: '格斗' },
            { type_id: '科幻', type_name: '科幻' },
            { type_id: '校园', type_name: '校园' },
            { type_id: '神鬼', type_name: '神鬼' },
            { type_id: '冒险', type_name: '冒险' },
            { type_id: '悬疑', type_name: '悬疑' },
            { type_id: '恐怖', type_name: '恐怖' },
            { type_id: '生活', type_name: '生活' },
            { type_id: '少年', type_name: '少年' },
            { type_id: '少女', type_name: '少女' },
            { type_id: '竞技', type_name: '竞技' },
            { type_id: '魔法', type_name: '魔法' },
            { type_id: '冒险', type_name: '冒险' },
            { type_id: '玄幻', type_name: '玄幻' },
            { type_id: '穿越', type_name: '穿越' },
            { type_id: '都市', type_name: '都市' },
            { type_id: '总裁', type_name: '总裁' },
        ],
    };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    const pg = inReq.body.page || 1;
    const reqUrl = `${url}/api/v1/comics?platform=2&page=${pg}&size=20&theme=${tid === '全部' ? '' : tid}`;
    let data = await req.get(reqUrl, {
        headers: { 'User-Agent': UA },
    });
    const content = data.data;
    let videos = [];
    if (content && content.results && content.results.list) {
        for (const comic of content.results.list) {
            videos.push({
                vod_id: comic.path_word,
                vod_name: comic.name,
                vod_pic: comic.cover,
                vod_remarks: comic.addtime || '',
            });
        }
    }
    const total = content ? content.results.total : videos.length;
    return {
        page: pg,
        pagecount: Math.ceil(total / 20),
        total: total,
        list: videos,
    };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const videos = [];
    for (const id of ids) {
        const reqUrl = `${url}/api/v1/comics/${id}?platform=2`;
        let data = await req.get(reqUrl, {
            headers: { 'User-Agent': UA },
        });
        const comic = data.data;
        if (!comic) continue;
        const chapters = comic.chapters ? comic.chapters[0].data : [];
        let playlist = [];
        for (const ch of chapters) {
            playlist.push(`${ch.name}$${ch.path_word}`);
        }
        videos.push({
            vod_id: id,
            vod_name: comic.name,
            vod_pic: comic.cover,
            vod_content: comic.description || '',
            vod_play_from: 'copymanga',
            vod_play_url: playlist.join('#'),
        });
    }
    return { list: videos };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    const reqUrl = `${url}/api/v1/comics/${id}/chapter?platform=2`;
    let data = await req.get(reqUrl, {
        headers: { 'User-Agent': UA },
    });
    const chapter = data.data;
    if (chapter && chapter.contents) {
        const urls = chapter.contents.map(c => c.url);
        return { parse: 0, content: urls.join('\n') };
    }
    return { parse: 0, content: '' };
}

async function search(inReq, _outResp) {
    const wd = inReq.body.wd;
    const pg = inReq.body.page || 1;
    const reqUrl = `${url}/api/v1/search/comic?platform=2&page=${pg}&size=20&q=${encodeURIComponent(wd)}`;
    let data = await req.get(reqUrl, {
        headers: { 'User-Agent': UA },
    });
    const content = data.data;
    let videos = [];
    if (content && content.results) {
        for (const comic of content.results) {
            videos.push({
                vod_id: comic.path_word,
                vod_name: comic.name,
                vod_pic: comic.cover,
                vod_remarks: '',
            });
        }
    }
    return { page: pg, pagecount: 1, list: videos };
}

export default {
    meta: { key: 'copymanga', name: 'Copy漫画', type: 23 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
