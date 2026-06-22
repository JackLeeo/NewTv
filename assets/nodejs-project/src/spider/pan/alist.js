import req from '../../util/req.js';
import { PC_UA, fixUrl } from '../../util/misc.js';

async function init(inReq, _outResp) {
    return {};
}

async function home(_inReq, _outResp) {
    const servers = inReq.server.config.alist || [];
    return {
        class: servers.map((s, i) => ({
            type_id: i.toString(),
            type_name: s.name,
        })),
    };
}

async function category(inReq, _outResp) {
    const tid = parseInt(inReq.body.id);
    const pg = inReq.body.page || 1;
    const servers = inReq.server.config.alist || [];
    if (tid < 0 || tid >= servers.length) {
        return { page: 1, pagecount: 1, list: [] };
    }
    const server = servers[tid];
    const reqUrl = `${server.server}/api/fs/list?path=/&page=${pg}&per_page=50`;
    let data = await req.get(reqUrl, {
        headers: { 'User-Agent': PC_UA },
    });
    const content = data.data;
    let videos = [];
    if (content.code === 200 && content.data && content.data.files) {
        for (const f of content.data.files) {
            if (f.type === 1) {
                videos.push({
                    vod_id: JSON.stringify({ server: tid, path: f.path }),
                    vod_name: f.name,
                    vod_pic: 'https://img.审美啦.com/favicon.ico',
                    vod_remarks: '',
                });
            }
        }
    }
    const total = content.data ? content.data.total : videos.length;
    return {
        page: pg,
        pagecount: Math.ceil(total / 50),
        total: total,
        list: videos,
    };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const servers = inReq.server.config.alist || [];
    const videos = [];
    for (const id of ids) {
        let obj;
        try {
            obj = JSON.parse(id);
        } catch {
            continue;
        }
        const server = servers[parseInt(obj.server)];
        if (!server) continue;
        const reqUrl = `${server.server}/api/fs/list?path=${encodeURIComponent(obj.path)}&page=1&per_page=200`;
        let data = await req.get(reqUrl, {
            headers: { 'User-Agent': PC_UA },
        });
        const content = data.data;
        let playlist = [];
        if (content.code === 200 && content.data && content.data.files) {
            for (const f of content.data.files) {
                if (f.type === 1) {
                    playlist.push(f.name + '$' + JSON.stringify({ server: obj.server, path: f.path }));
                }
            }
        }
        if (playlist.length > 0) {
            videos.push({
                vod_id: id,
                vod_name: 'Alist',
                vod_pic: 'https://img.审美啦.com/favicon.ico',
                vod_play_from: 'Alist',
                vod_play_url: playlist.join('#'),
            });
        }
    }
    return { list: videos };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    let obj;
    try {
        obj = JSON.parse(id);
    } catch {
        return { parse: 0, url: id };
    }
    const servers = inReq.server.config.alist || [];
    const server = servers[parseInt(obj.server)];
    if (!server) return { parse: 0, url: id };
    const reqUrl = `${server.server}/api/fs/get`;

    let data = await req.post(reqUrl, {
        path: obj.path,
    }, {
        headers: { 'User-Agent': PC_UA },
    });

    if (data.data && data.data.raw_url) {
        return { parse: 0, url: data.data.raw_url, header: { 'User-Agent': PC_UA } };
    }
    return { parse: 0, url: id };
}

async function search(inReq, _outResp) {
    const wd = inReq.body.wd;
    const pg = inReq.body.page || 1;
    const servers = inReq.server.config.alist || [];
    const videos = [];
    for (const server of servers) {
        const reqUrl = `${server.server}/api/fs/search?path=/&keyword=${encodeURIComponent(wd)}&page=${pg}&per_page=50`;
        try {
            let data = await req.get(reqUrl, {
                headers: { 'User-Agent': PC_UA },
            });
            const content = data.data;
            if (content.code === 200 && content.data && content.data.files) {
                for (const f of content.data.files) {
                    if (f.type === 1) {
                        videos.push({
                            vod_id: JSON.stringify({ server: servers.indexOf(server), path: f.path }),
                            vod_name: f.name,
                            vod_pic: 'https://img.审美啦.com/favicon.ico',
                            vod_remarks: server.name,
                        });
                    }
                }
            }
        } catch (e) {
            console.error(e);
        }
    }
    return { page: pg, pagecount: 1, list: videos };
}

export default {
    meta: { key: 'alist', name: 'Alist', type: 43 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
