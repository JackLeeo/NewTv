import req from './req.js';
import chunkStream  from './chunk.js';
import CryptoJS from 'crypto-js';
import { formatPlayUrl, conversion, lcs, findBestLCS, delay} from './misc.js';
import axios from "axios";

export const Addition = {
    DeviceID: '07b48aaba8a739356ab8107b5e230ad4',
    RefreshToken: '',
    AccessToken: ''
}

export const conf = {
    api:      "https://open-api-drive.uc.cn",
    clientID: "5acf882d27b74502b7040b0c65519aa7",
    signKey:  "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d",
    appVer:   "1.6.8",
    channel:  "UCTVOFFICIALWEB",
    codeApi:  "http://api.extscreen.com/ucdrive",
}

export function generateDeviceID(timestamp) {
    return CryptoJS.MD5(timestamp).toString().slice(0, 16);
}

export function generateReqId(deviceID, timestamp) {
    return CryptoJS.MD5(deviceID + timestamp).toString().slice(0, 16);
}

export function generateXPanToken(method, pathname, timestamp, key) {
    const data = method + '&' + pathname + '&' + timestamp + '&' + key;
    return CryptoJS.SHA256(data).toString();
}

export function getShareData(url) {
    let regex = /https:\/\/drive\.uc\.cn\/s\/([^\\|#/?]+)/;
    let matches = regex.exec(url);
    if (matches) {
        return {
            shareId: matches[1],
            folderId: '0',
        };
    }
    return null;
}

const pr = 'pr=UCBrowser&fr=pc';

export const baseHeader = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch',
    Referer: 'https://drive.uc.cn',
};

let localDb = null;
let ckey = null;

const apiUrl = 'https://pc-api.uc.cn/1/clouddrive/';
export let cookie = '';
export let tokenDbKey = '';

const shareTokenCache = {};
const saveDirName = 'CatVodOpen';
let saveDirId = null;

export async function initUC(inReq) {
    localDb = inReq.server.db;
    const cfg = inReq.server.config.uc
    cookie = cfg.cookie;
    ckey = CryptoJS.enc.Hex.stringify(CryptoJS.MD5(cfg.cookie)).toString();
    tokenDbKey = CryptoJS.enc.Hex.stringify(CryptoJS.MD5(cfg.token)).toString();
    const localCfg = await localDb.getObjectDefault(`/uc`, {});
    if (localCfg[ckey]) {
        cookie = localCfg[ckey];
    }
}

async function api(url, data, headers, method, retry) {
    headers = headers || {};
    Object.assign(headers, baseHeader);
    Object.assign(headers, {
        Cookie: cookie || '',
    });
    method = method || 'post';
    const resp =
        method == 'get'
            ? await req
                  .get(`${apiUrl}/${url}`, {
                      headers: headers,
                  })
                  .catch((err) => {
                      console.error(err);
                      return err.response || { status: 500, data: {} };
                  })
            : await req
                  .post(`${apiUrl}/${url}`, data, {
                      headers: headers,
                  })
                  .catch((err) => {
                      console.error(err);
                      return err.response || { status: 500, data: {} };
                  });
    const leftRetry = retry || 3;
    if (resp.headers['set-cookie']) {
        const puus = resp.headers['set-cookie'].join(';;;').match(/__puus=([^;]+)/);
        if (puus) {
            if (cookie.match(/__puus=([^;]+)/)[1] != puus[1]) {
                cookie = cookie.replace(/__puus=[^;]+/, `__puus=${puus[1]}`);
                await localDb.push(`/uc/${ckey}`, cookie);
            }
        }
    }
    if (resp.status === 429 && leftRetry > 0) {
        await delay(1000);
        return await api(url, data, headers, method, leftRetry - 1);
    }
    return resp.data || {};
}

async function clearSaveDir() {
    const listData = await api(`file/sort?${pr}&pdir_fid=${saveDirId}&_page=1&_size=200&_sort=file_type:asc,updated_at:desc`, {}, {}, 'get');
    if (listData.data && listData.data.list && listData.data.list.length > 0) {
        const del = await api(`file/delete?${pr}`, {
            action_type: 2,
            filelist: listData.data.list.map((v) => v.fid),
            exclude_fids: [],
        });
        console.log(del);
    }
}

async function createSaveDir(clean) {
    if (saveDirId) {
        if (clean) await clearSaveDir();
        return;
    }
    const listData = await api(`file/sort?${pr}&pdir_fid=0&_page=1&_size=200&_sort=file_type:asc,updated_at:desc`, {}, {}, 'get');
    if (listData.data && listData.data.list)
        for (const item of listData.data.list) {
            if (item.file_name === saveDirName) {
                saveDirId = item.fid;
                await clearSaveDir();
                break;
            }
        }
    if (!saveDirId) {
        const create = await api(`file?${pr}`, {
            pdir_fid: '0',
            file_name: saveDirName,
            dir_path: '',
            dir_init_lock: false,
        });
        console.log(create);
        if (create.data && create.data.fid) {
            saveDirId = create.data.fid;
        }
    }
}

async function getShareToken(shareData) {
    if (!shareTokenCache[shareData.shareId]) {
        delete shareTokenCache[shareData.shareId];
        const shareToken = await api(`share/sharepage/token?${pr}`, {
            pwd_id: shareData.shareId,
            passcode: shareData.sharePwd || '',
        });
        if (shareToken.data && shareToken.data.stoken) {
            shareTokenCache[shareData.shareId] = shareToken.data;
        }
    }
}

const subtitleExts = ['.srt', '.ass', '.scc', '.stl', '.ttml'];

export async function getFilesByShareUrl(shareInfo) {
    const shareData = typeof shareInfo === 'string' ? getShareData(shareInfo) : shareInfo;
    if (!shareData) return [];
    await getShareToken(shareData);
    if (!shareTokenCache[shareData.shareId]) return [];
    const videos = [];
    const subtitles = [];
    const listFile = async function (shareId, folderId, page) {
        const prePage = 200;
        page = page || 1;
        const listData = await api(`share/sharepage/detail?${pr}&pwd_id=${shareId}&stoken=${encodeURIComponent(shareTokenCache[shareId].stoken)}&pdir_fid=${folderId}&force=0&_page=${page}&_size=${prePage}&_sort=file_type:asc,file_name:asc`, {}, {}, 'get');
        if (!listData.data) return [];
        const items = listData.data.list;
        if (!items) return [];
        const subDir = [];

        for (const item of items) {
            if (item.dir === true) {
                subDir.push(item);
            } else if (item.file === true && item.obj_category === 'video') {
                if (item.size < 1024 * 1024 * 5) continue;
                item.stoken = shareTokenCache[shareData.shareId].stoken;
                videos.push(item);
            } else if (item.type === 'file' && subtitleExts.some((x) => item.file_name.endsWith(x))) {
                subtitles.push(item);
            }
        }

        if (page < Math.ceil(listData.metadata._total / prePage)) {
            const nextItems = await listFile(shareId, folderId, page + 1);
            for (const item of nextItems) {
                items.push(item);
            }
        }

        for (const dir of subDir) {
            const subItems = await listFile(shareId, dir.fid);
            for (const item of subItems) {
                items.push(item);
            }
        }

        return items;
    };
    await listFile(shareData.shareId, shareData.folderId);
    if (subtitles.length > 0) {
        videos.forEach((item) => {
            var matchSubtitle = findBestLCS(item, subtitles);
            if (matchSubtitle.bestMatch) {
                item.subtitle = matchSubtitle.bestMatch.target;
            }
        });
    }

    return videos;
}

const saveFileIdCaches = {};

async function save(shareId, stoken, fileId, fileToken, clean) {
    await createSaveDir(clean);
    if (clean) {
        const saves = Object.keys(saveFileIdCaches);
        for (const save of saves) {
            delete saveFileIdCaches[save];
        }
    }
    if (!saveDirId) return null;
    if (!stoken) {
        await getShareToken({
            shareId: shareId,
        });
        if (!shareTokenCache[shareId]) return null;
    }
    const saveResult = await api(`share/sharepage/save?${pr}`, {
        fid_list: [fileId],
        fid_token_list: [fileToken],
        to_pdir_fid: saveDirId,
        pwd_id: shareId,
        stoken: stoken || shareTokenCache[shareId].stoken,
        pdir_fid: '0',
        scene: 'link',
    });
    if (saveResult.data && saveResult.data.task_id) {
        let retry = 0;
        while (true) {
            const taskResult = await api(`task?${pr}&task_id=${saveResult.data.task_id}&retry_index=${retry}`, {}, {}, 'get');
            if (taskResult.data && taskResult.data.save_as && taskResult.data.save_as.save_as_top_fids && taskResult.data.save_as.save_as_top_fids.length > 0) {
                return taskResult.data.save_as.save_as_top_fids[0];
            }
            retry++;
            if (retry > 5) break;
            await delay(1000);
        }
    }
    return false;
}

export async function getLiveTranscoding(shareId, stoken, fileId, fileToken) {
    if (!saveFileIdCaches[fileId]) {
        const saveFileId = await save(shareId, stoken, fileId, fileToken, true);
        if (!saveFileId) return null;
        saveFileIdCaches[fileId] = saveFileId;
    }
    const transcoding = await api(`file/v2/play?${pr}`, {
        fid: saveFileIdCaches[fileId],
        resolutions: 'normal,low,high,super,2k,4k',
        supports: 'fmp4',
    });
    if (transcoding.data && transcoding.data.video_list) {
        return transcoding.data.video_list;
    }
    return null;
}

export async function getDownload(shareId, stoken, fileId, fileToken, clean) {
    if (!saveFileIdCaches[fileId]) {
        const saveFileId = await save(shareId, stoken, fileId, fileToken, clean);
        if (!saveFileId) return null;
        saveFileIdCaches[fileId] = saveFileId;
    }
    const localCfg = await localDb.getObjectDefault(`/uc`, {});
    const token = localCfg[tokenDbKey]
    console.log('localCfg', localCfg, token)
    if (token) {
        let video = []
        const pathname = '/file';
        const timestamp = Math.floor(Date.now() / 1000).toString() + '000';
        const deviceID = Addition.DeviceID || generateDeviceID(timestamp);
        const reqId = generateReqId(deviceID, timestamp);
        const x_pan_token = generateXPanToken("GET", pathname, timestamp, conf.signKey);
        let config = {
            method: 'GET',
            url: `https://open-api-drive.uc.cn/file`,
            params: {
                req_id: reqId,
                access_token: token,
                app_ver: conf.appVer,
                device_id: deviceID,
                device_brand: 'Xiaomi',
                platform: 'tv',
                device_name: 'M2004J7AC',
                device_model: 'M2004J7AC',
                build_device: 'M2004J7AC',
                build_product: 'M2004J7AC',
                device_gpu: 'Adreno (TM) 550',
                activity_rect: '{}',
                channel: conf.channel,
                method: "download",
                group_by: "source",
                fid: saveFileIdCaches[fileId],
                resolution: "low,normal,high,super,2k,4k",
                support: "dolby_vision"
            },
            headers: {
                'User-Agent': 'Mozilla/5.0 (Linux; U; Android 9; zh-cn; RMX1931 Build/PQ3A.190605.05081124) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1',
                'Connection': 'Keep-Alive',
                'Accept-Encoding': 'gzip',
                'x-pan-tm': timestamp,
                'x-pan-token': x_pan_token,
                'content-type': 'text/plain;charset=UTF-8',
                'x-pan-client-id': conf.clientID
            }
        }
        let req = await axios.request(config);
        if (req.status === 200) {
            return req.data.data
        }
    } else {
        const down = await api(`file/download?${pr}`, {
            fids: [saveFileIdCaches[fileId]],
        });
        if (down.data) {
            return down.data[0];
        }
    }
    return null;
}

export async function detail(shareUrl) {
    if (shareUrl.includes('https://drive.uc.cn')) {
        const shareData = getShareData(shareUrl);
        const result = {};
        if (shareData) {
            const videos = await getFilesByShareUrl(shareData);
            if (videos.length > 0) {
                result.from = 'UC网盘-' + shareData.shareId;
                result.url = videos
                        .map((v) => {
                            const ids = [shareData.shareId, v.stoken, v.fid, v.share_fid_token, v.subtitle ? v.subtitle.fid : '', v.subtitle ? v.subtitle.share_fid_token : ''];
                            const size = conversion(v.size);
                            return formatPlayUrl('', ` ${v.file_name.replace(/.[^.]+$/,'')}  [${size}]`) + '$' + ids.join('*');
                        })
                        .join('#')
            }
        }
        return result;
    }
}

const ucTranscodingCache = {};
const ucDownloadingCache = {};

export async function proxy(inReq, outResp) {
    const site = inReq.params.site;
    const what = inReq.params.what;
    const shareId = inReq.params.shareId;
    const fileId = inReq.params.fileId;
    await initUC(inReq)
    if (site == 'uc') {
        let downUrl = '';
        const ids = fileId.split('*');
        const flag = inReq.params.flag;
        if (what == 'trans') {
            if (!ucTranscodingCache[ids[1]]) {
                ucTranscodingCache[ids[1]] = (await getLiveTranscoding(shareId, decodeURIComponent(ids[0]), ids[1], ids[2])).filter((t) => t.accessable);
            }
            downUrl = ucTranscodingCache[ids[1]].filter((t) => t.resolution.toLowerCase() == flag)[0].video_info.url;
            outResp.redirect(downUrl);
            return;
        } else {
            if (!ucDownloadingCache[ids[1]]) {
                const down = await getDownload(shareId, decodeURIComponent(ids[0]), ids[1], ids[2], flag == 'down');
                if (down) ucDownloadingCache[ids[1]] = down;
            }
            downUrl = ucDownloadingCache[ids[1]].download_url;
            if (flag == 'redirect') {
                outResp.redirect(downUrl);
                return;
            }
        }
        return await chunkStream(
            inReq,
            outResp,
            downUrl,
            ids[1],
            Object.assign(
                {
                    Cookie: cookie,
                },
                baseHeader,
            ),
        );
    }
}

export async function play(inReq, outResp) {
    const flag = inReq.body.flag;
    const id = inReq.body.id;
    const ids = id.split('*');
    await initUC(inReq)
    let idx = 0;
    if (flag.startsWith('UC网盘')) {
        const transcoding = (await getLiveTranscoding(ids[0], ids[1], ids[2], ids[3])).filter((t) => t.accessable);
        ucTranscodingCache[ids[2]] = transcoding;
        const urls = [];
        const p= ['超清','蓝光','高清','标清','普画','极速'];
        const arr =['4k','2k','super','high','low','normal'];
        const proxyUrl = inReq.server.address().url + inReq.server.prefix + '/proxy/uc';
        urls.push('代理');
        urls.push(`${proxyUrl}/src/down/${ids[0]}/${encodeURIComponent(ids[1])}*${ids[2]}*${ids[3]}/.bin`);
        urls.push('原画');
        urls.push(`${proxyUrl}/src/redirect/${ids[0]}/${encodeURIComponent(ids[1])}*${ids[2]}*${ids[3]}/.bin`);
        const result = {
            parse: 0,
            url: urls,
            header: Object.assign(
                {
                    Cookie: cookie,
                },
                baseHeader,
            ),
        };
        if (ids[3]) {
            result.extra = {
                subt: `${proxyUrl}/src/subt/${ids[0]}/${encodeURIComponent(ids[1])}*${ids[4]}*${ids[5]}/.bin`,
            };
        }
        transcoding.forEach((t) => {
            idx = arr.indexOf(t.resolution);
            urls.push(p[idx]);
            urls.push(`${proxyUrl}/trans/${t.resolution.toLowerCase()}/${ids[0]}/${encodeURIComponent(ids[1])}*${ids[2]}*${ids[3]}/.mp4`);
        });
        return result;
    }
}
