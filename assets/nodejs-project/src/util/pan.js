import { IOS_UA, isEmpty} from './misc.js';
import * as Ali from './ali.js';
import * as Quark from './quark.js';
import * as UC from './uc.js';

export { isEmpty };
export const ua = IOS_UA;

export async function init(inReq, _outResp) {
    await Ali.initAli(inReq.server.db, inReq.server.config.ali);
    await Quark.initQuark(inReq.server.db, inReq.server.config.quark);
    await UC.initUC(inReq);
    return {};
}

export async function detail(shareUrls) {
        shareUrls = !Array.isArray(shareUrls) ? [shareUrls] : shareUrls;
        const froms = [];
        const urls = [];
        for (const shareUrl of shareUrls) {
            if (shareUrl.includes('https://www.alipan.com')) {
                const data = await Ali.detail(shareUrl);
                if(data){
                    froms.push(data.from);
                    urls.push(data.url);
                }
            } else if (shareUrl.includes('https://pan.quark.cn')) {
                const data = await Quark.detail(shareUrl);
                if(data){
                    froms.push(data.from);
                    urls.push(data.url);
                }
            } else if (shareUrl.includes('https://drive.uc.cn')) {
                const data = await UC.detail(shareUrl);
                if(data){
                    froms.push(data.from);
                    urls.push(data.url);
                }
            }
        }

        return {
            froms: froms.join('$$$'),
            urls: urls.join('$$$')
        };
}

export async function proxy(inReq, _outResp) {
    const site = inReq.params.site;
    if (site == 'ali') {
        return await Ali.proxy(inReq, _outResp);
    } else if (site == 'quark') {
        return await Quark.proxy(inReq, _outResp);
    } else if (site == 'uc') {
        return await UC.proxy(inReq, _outResp);
    }
}

export async function play(inReq, _outResp) {
    const flag = inReq.body.flag;
    if (flag.startsWith('阿里云盘')) {
        return await Ali.play(inReq, _outResp);
    } else if (flag.startsWith('夸克网盘')) {
        return await Quark.play(inReq, _outResp);
    } else if (flag.startsWith('UC网盘')) {
        return await UC.play(inReq, _outResp);
    }
}

export async function test(inReq, outResp) {
    try {
        const prefix = inReq.server.prefix;
        const dataResult = {};
        let resp = await inReq.server.inject().post(`${prefix}/init`);
        dataResult.init = resp.json();
        printErr(resp.json());
        resp = await inReq.server.inject().post(`${prefix}/home`);
        dataResult.home = resp.json();
        printErr(resp.json());
        let detailCalled = false;
        if (dataResult.home.class && dataResult.home.class.length > 0) {
            const typeId = dataResult.home.class[0].type_id;
            let filters = {};
            if (dataResult.home.filters) {
                let filter = dataResult.home.filters[typeId];
                if (filter) {
                    for (const filterCfg of filter) {
                        const initValue = filterCfg.init;
                        if (!initValue) continue;
                        for (const value of filterCfg.value) {
                            if (value.v == initValue) {
                                filters[filterCfg.key] = initValue;
                                break;
                            }
                        }
                    }
                }
            }
            resp = await inReq.server.inject().post(`${prefix}/category`).payload({
                id: typeId,
                page: 1,
                filter: true,
                filters: filters,
            });
            dataResult.category = resp.json();
            printErr(resp.json());
            if (dataResult.category.list.length > 0) {
                detailCalled = true;
                const vodId = dataResult.category.list[0].vod_id;
                await detailTest(inReq, vodId, dataResult);
            }
        }
        resp = await inReq.server.inject().post(`${prefix}/search`).payload({
            wd: '仙逆',
            page: 1,
        });
        dataResult.search = resp.json();
        if (!detailCalled && dataResult.search.list.length > 0) {
            const vodId = dataResult.search.list[0].vod_id;
            await detailTest(inReq, vodId, dataResult);
        }
        printErr(resp.json());
        return dataResult;
    } catch (err) {
        console.error(err);
        outResp.code(500);
        return { err: err.message, tip: 'check debug console output' };
    }
}

async function detailTest(inReq, vodId, dataResult) {
    const prefix = inReq.server.prefix;
    let resp = await inReq.server.inject().post(`${prefix}/detail`).payload({
        id: vodId,
    });
    dataResult.detail = resp.json();
    printErr(resp.json());
    if (dataResult.detail.list && dataResult.detail.list.length > 0) {
        dataResult.play = [];
        for (const vod of dataResult.detail.list) {
            const flags = vod.vod_play_from.split('$$$');
            const ids = vod.vod_play_url.split('$$$');
            for (let j = 0; j < flags.length; j++) {
                const flag = flags[j];
                const urls = ids[j].split('#');
                for (let i = 0; i < urls.length && i < 2; i++) {
                    resp = await inReq.server
                        .inject()
                        .post(`${prefix}/play`)
                        .payload({
                            flag: flag,
                            id: urls[i].split('$')[1],
                        });
                    dataResult.play.push(resp.json());
                }
            }
        }
    }
}

function printErr(json) {
    if (json.statusCode && json.statusCode == 500) {
        console.error(json);
    }
}
