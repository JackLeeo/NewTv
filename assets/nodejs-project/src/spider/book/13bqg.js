import req from '../../util/req.js';
import { UA } from '../../util/misc.js';

let url = '';

async function request(reqUrl, options = {}) {
    const resp = await req.get(reqUrl, {
        headers: {
            'User-Agent': options.ua || UA,
            Referer: url,
        },
    });
    return resp.data;
}

async function init(inReq, _outResp) {
    url = inReq.server.config['13bqg']?.url || 'https://www.13bqg.com';
    return {};
}

async function home(_inReq, _outResp) {
    return {
        class: [
            { type_id: 'xuanhuan', type_name: '玄幻小说' },
            { type_id: 'xiuxian', type_name: '修真小说' },
            { type_id: 'dushi', type_name: '都市小说' },
            { type_id: 'lingyu', type_name: '网游小说' },
            { type_id: 'kongbu', type_name: '恐怖小说' },
            { type_id: 'wangyou', type_name: '其他小说' },
        ],
    };
}

async function category(inReq, _outResp) {
    const tid = inReq.body.id;
    const pg = inReq.body.page || 1;
    const reqUrl = `${url}/book/${tid}/${pg}.html`;
    let html = await request(reqUrl);
    let listMatch = html.match(/<div class="uk-width-3-4">([\s\S]*?)<\/div>\s*<\/div>/);
    if (!listMatch) return { page: 1, pagecount: 1, list: [] };
    const items = listMatch[1].match(/<a[^>]*href="\/book\/detail\/([^"]+)"[^>]*>\s*<img[^>]*src="([^"]+)"[^>]*>[\s\S]*?<h4[^>]*>([^<]+)<\/h4>/g) || [];
    const videos = items.map(item => {
        const hrefMatch = item.match(/href="\/book\/detail\/([^"]+)"/);
        const imgMatch = item.match(/src="([^"]+)"/);
        const nameMatch = item.match(/<h4[^>]*>([^<]+)<\/h4>/);
        return {
            vod_id: hrefMatch ? hrefMatch[1] : '',
            vod_name: nameMatch ? nameMatch[1].trim() : '',
            vod_pic: imgMatch ? imgMatch[1] : '',
            vod_remarks: '',
        };
    });
    const hasMore = html.includes('下一页');
    return {
        page: pg,
        pagecount: hasMore ? pg + 1 : pg,
        total: videos.length * pg,
        list: videos,
    };
}

async function detail(inReq, _outResp) {
    const ids = !Array.isArray(inReq.body.id) ? [inReq.body.id] : inReq.body.id;
    const videos = [];
    for (const id of ids) {
        const reqUrl = `${url}/book/detail/${id}.html`;
        let html = await request(reqUrl);
        const nameMatch = html.match(/<h1[^>]*>([^<]+)<\/h1>/);
        const imgMatch = html.match(/<img[^>]*class="uk-width-1-3"[^>]*src="([^"]+)"[^>]*>/);
        const descMatch = html.match(/<div[^>]*class="content[^"]*"[^>]*>([\s\S]*?)<\/div>/);
        const listMatch = html.match(/<ul[^>]*class="chapter-list[^"]*"[^>]*>([\s\S]*?)<\/ul>/);
        let playlist = [];
        if (listMatch) {
            const chapters = listMatch[1].match(/<a[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/g) || [];
            playlist = chapters.map(ch => {
                const hrefMatch = ch.match(/href="([^"]+)"/);
                const nameMatch = ch.match(/>([^<]+)<\/a>/);
                return (nameMatch ? nameMatch[1] : '') + '$' + (hrefMatch ? hrefMatch[1] : '');
            });
        }
        videos.push({
            vod_id: id,
            vod_name: nameMatch ? nameMatch[1].trim() : id,
            vod_pic: imgMatch ? imgMatch[1] : '',
            vod_content: descMatch ? descMatch[1].replace(/<[^>]+>/g, '').trim() : '',
            vod_play_from: '13bqg',
            vod_play_url: playlist.join('#'),
        });
    }
    return { list: videos };
}

async function play(inReq, _outResp) {
    const id = inReq.body.id;
    const reqUrl = `${url}${id}`;
    let html = await request(reqUrl);
    const contentMatch = html.match(/<div[^>]*class="uk-width-1-1"[^>]*>([\s\S]*?)<\/div>/);
    if (contentMatch) {
        let content = contentMatch[1].replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '').trim();
        return { parse: 0, content: content };
    }
    return { parse: 0, content: '' };
}

async function search(inReq, _outResp) {
    const wd = inReq.body.wd;
    const pg = inReq.body.page || 1;
    const reqUrl = `${url}/book/search?searchword=${encodeURIComponent(wd)}&page=${pg}`;
    let html = await request(reqUrl);
    const items = html.match(/<a[^>]*href="\/book\/detail\/([^"]+)"[^>]*>\s*<img[^>]*src="([^"]+)"[^>]*>[\s\S]*?<h4[^>]*>([^<]+)<\/h4>/g) || [];
    const videos = items.map(item => {
        const hrefMatch = item.match(/href="\/book\/detail\/([^"]+)"/);
        const imgMatch = item.match(/src="([^"]+)"/);
        const nameMatch = item.match(/<h4[^>]*>([^<]+)<\/h4>/);
        return {
            vod_id: hrefMatch ? hrefMatch[1] : '',
            vod_name: nameMatch ? nameMatch[1].trim() : '',
            vod_pic: imgMatch ? imgMatch[1] : '',
            vod_remarks: '',
        };
    });
    return { page: pg, pagecount: 1, list: videos };
}

export default {
    meta: { key: '13bqg', name: '13看书', type: 13 },
    api: async (fastify) => {
        fastify.post('/init', init);
        fastify.post('/home', home);
        fastify.post('/category', category);
        fastify.post('/detail', detail);
        fastify.post('/play', play);
        fastify.post('/search', search);
    },
};
