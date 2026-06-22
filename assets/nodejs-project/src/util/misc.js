var charStr = 'abacdefghjklmnopqrstuvwxyzABCDEFGHJKLMNOPQRSTUVWXYZ0123456789';

export function rand(min, max) {
    return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function randStr(len, withNum, onlyNum) {
    var _str = '';
    let containsNum = withNum === undefined ? true : withNum;
    for (var i = 0; i < len; i++) {
        let idx = onlyNum ? rand(charStr.length - 10, charStr.length - 1) : rand(0, containsNum ? charStr.length - 1 : charStr.length - 11);
        _str += charStr[idx];
    }
    return _str;
}

export function randUUID() {
    return randStr(8).toLowerCase() + '-' + randStr(4).toLowerCase() + '-' + randStr(4).toLowerCase() + '-' + randStr(4).toLowerCase() + '-' + randStr(12).toLowerCase();
}

export function randMAC() {
    return randStr(2).toUpperCase() + ':' + randStr(2).toUpperCase() + ':' + randStr(2).toUpperCase() + ':' + randStr(2).toUpperCase() + ':' + randStr(2).toUpperCase() + ':' + randStr(2).toUpperCase();
}

const deviceBrands = ['Huawei', 'Xiaomi'];
const deviceModels = [
    ['MHA-AL00', 'HUAWEI Mate 9', 'MHA-TL00', 'HUAWEI Mate 9', 'LON-AL00', 'HUAWEI Mate 9 Pro', 'ALP-AL00', 'HUAWEI Mate 10', 'ALP-TL00', 'HUAWEI Mate 10', 'BLA-AL00', 'HUAWEI Mate 10 Pro', 'BLA-TL00', 'HUAWEI Mate 10 Pro', 'HMA-AL00', 'HUAWEI Mate 20', 'HMA-TL00', 'HUAWEI Mate 20', 'LYA-AL00', 'HUAWEI Mate 20 Pro', 'LYA-AL10', 'HUAWEI Mate 20 Pro', 'LYA-TL00', 'HUAWEI Mate 20 Pro', 'EVR-AL00', 'HUAWEI Mate 20 X', 'EVR-TL00', 'HUAWEI Mate 20 X', 'EVR-AN00', 'HUAWEI Mate 20 X', 'TAS-AL00', 'HUAWEI Mate 30', 'TAS-TL00', 'HUAWEI Mate 30', 'TAS-AN00', 'HUAWEI Mate 30', 'TAS-TN00', 'HUAWEI Mate 30', 'LIO-AL00', 'HUAWEI Mate 30 Pro', 'LIO-TL00', 'HUAWEI Mate 30 Pro', 'LIO-AN00', 'HUAWEI Mate 30 Pro', 'LIO-TN00', 'HUAWEI Mate 30 Pro', 'LIO-AN00m', 'HUAWEI Mate 30E Pro', 'OCE-AN10', 'HUAWEI Mate 40', 'OCE-AN50', 'HUAWEI Mate 40E', 'OCE-AL50', 'HUAWEI Mate 40E', 'NOH-AN00', 'HUAWEI Mate 40 Pro', 'NOH-AN01', 'HUAWEI Mate 40 Pro', 'NOH-AL00', 'HUAWEI Mate 40 Pro', 'NOH-AL10', 'HUAWEI Mate 40 Pro', 'NOH-AN50', 'HUAWEI Mate 40E Pro', 'NOP-AN00', 'HUAWEI Mate 40 Pro', 'CET-AL00', 'HUAWEI Mate 50', 'CET-AL60', 'HUAWEI Mate 50E', 'DCO-AL00', 'HUAWEI Mate 50 Pro', 'TAH-AN00', 'HUAWEI Mate X', 'TAH-AN00m', 'HUAWEI Mate Xs', 'TET-AN00', 'HUAWEI Mate X2', 'TET-AN10', 'HUAWEI Mate X2', 'TET-AN50', 'HUAWEI Mate X2', 'TET-AL00', 'HUAWEI Mate X2', 'PAL-AL00', 'HUAWEI Mate Xs 2', 'PAL-AL10', 'HUAWEI Mate Xs 2', 'EVA-AL00', 'HUAWEI P9', 'EVA-AL10', 'HUAWEI P9', 'EVA-TL00', 'HUAWEI P9', 'EVA-DL00', 'HUAWEI P9', 'EVA-CL00', 'HUAWEI P9', 'VIE-AL10', 'HUAWEI P9 Plus', 'VTR-AL00', 'HUAWEI P10', 'VTR-TL00', 'HUAWEI P10', 'VKY-AL00', 'HUAWEI P10 Plus', 'VKY-TL00', 'HUAWEI P10 Plus', 'EML-AL00', 'HUAWEI P20', 'EML-TL00', 'HUAWEI P20', 'CLT-AL00', 'HUAWEI P20 Pro', 'CLT-AL01', 'HUAWEI P20 Pro', 'CLT-AL00l', 'HUAWEI P20 Pro', 'CLT-TL00', 'HUAWEI P20 Pro', 'CLT-TL01', 'HUAWEI P20 Pro', 'ELE-AL00', 'HUAWEI P30', 'ELE-TL00', 'HUAWEI P30', 'VOG-AL00', 'HUAWEI P30 Pro', 'VOG-AL10', 'HUAWEI P30 Pro'],
    ['M2001J2C', 'Xiaomi 10', 'M2001J2G', 'Xiaomi 10', 'M2001J2I', 'Xiaomi 10', 'M2011K2C', 'Xiaomi 11', 'M2011K2G', 'Xiaomi 11', '2201123C', 'Xiaomi 12', '2201123G', 'Xiaomi 12', '2112123AC', 'Xiaomi 12X', '2112123AG', 'Xiaomi 12X', '2201122C', 'Xiaomi 12 Pro', '2201122G', 'Xiaomi 12 Pro'],
];
export function randDevice() {
    let brandIdx = rand(0, deviceBrands.length - 1);
    let brand = deviceBrands[brandIdx];
    let modelIdx = rand(0, deviceModels[brandIdx].length / 2 - 1);
    let model = deviceModels[brandIdx][modelIdx * 2 + 1];
    let release = rand(8, 13);
    let buildId = randStr(3, false).toUpperCase() + rand(11, 99) + randStr(1, false).toUpperCase();
    return {
        brand: brand,
        model: model,
        release: release,
        buildId: buildId,
    };
}

export function randDeviceWithId(len) {
    let device = randDevice();
    device['id'] = randStr(len);
    return device;
}

export const MOBILE_UA = 'Mozilla/5.0 (Linux; Android 11; M2007J3SC Build/RKQ1.200826.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/77.0.3865.120 MQQBrowser/6.2 TBS/045714 Mobile Safari/537.36';
export const PC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/95.0.4638.54 Safari/537.36';
export const UA = 'Mozilla/5.0';
export const UC_UA = 'Mozilla/5.0 (Linux; U; Android 9; zh-CN; MI 9 Build/PKQ1.181121.001) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/57.0.2987.108 UCBrowser/12.5.5.1035 Mobile Safari/537.36';
export const IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1';
export const MAC_UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/72.0.3626.81 Safari/537.36 SE 2.X MetaSr 1.0';

export function formatPlayUrl(src, name) {
    if (src.trim() == name.trim()) {
        return name;
    }
    return name
      .trim()
      .replaceAll(src, '')
      .replace(/<|>|《|》/g, '')
      .replace(/\$|#/g, ' ')
      .trim();
}

export function formatPlayUrl2(src, name) {
    var idx = name.indexOf('$');
    if (idx <= 0) {
        return formatPlayUrl(src, name);
    }
    return formatPlayUrl(src, name.substring(0, idx)) + name.substring(idx);
}

export function stripHtmlTag(src) {
    return src
      .replace(/<\/?[^>]+(>|$)/g, '')
      .replace(/&.{1,5};/g, '')
      .replace(/\s{2,}/g, ' ');
}

export function fixUrl(base, src) {
    try {
        if (src.startsWith('//')) {
            let parse = new URL(base);
            let host = src.substring(2, src.indexOf('/', 2));
            if (!host.includes('.')) {
                src = parse.protocol + '://' + parse.host + src.substring(1);
            } else {
                src = parse.protocol + ':' + src;
            }
        } else if (!src.includes('://')) {
            let parse = new URL(base);
            src = parse.protocol + '://' + parse.host + src;
        }
    } catch (error) {}
    return src;
}

export function jsonParse(input, json) {
    try {
        let url = json.url || '';
        if (url.startsWith('//')) {
            url = 'https:' + url;
        }
        if (!url.startsWith('http')) {
            return {};
        }
        let headers = json['headers'] || {};
        let ua = (json['user-agent'] || '').trim();
        if (ua.length > 0) {
            headers['User-Agent'] = ua;
        }
        let referer = (json['referer'] || '').trim();
        if (referer.length > 0) {
            headers['Referer'] = referer;
        }
        return {
            header: headers,
            url: url,
        };
    } catch (error) {
        console.log(error);
    }
    return {};
}

export function conversion(bytes){
    let mb = bytes / (1024 * 1024);
    if(mb > 1024){
        return `${(mb/1024).toFixed(2)}GB`;
    }else{
        return `${parseInt(mb).toFixed(0)}MB`;
    }
}

export function isEmpty(value) {
    if (value === null || value === undefined) {
        return true;
    } else if (typeof value === 'string') {
        return value.length === 0;
    } else if (Array.isArray(value)) {
        return value.length === 0;
    } else {
        return false;
    }
}

export function lcs(str1, str2) {
    if (!str1 || !str2) {
        return {
            length: 0,
            sequence: '',
            offset: 0,
        };
    }

    var sequence = '';
    var str1Length = str1.length;
    var str2Length = str2.length;
    var num = new Array(str1Length);
    var maxlen = 0;
    var lastSubsBegin = 0;

    for (var i = 0; i < str1Length; i++) {
        var subArray = new Array(str2Length);
        for (var j = 0; j < str2Length; j++) {
            subArray[j] = 0;
        }
        num[i] = subArray;
    }
    var thisSubsBegin = null;
    for (i = 0; i < str1Length; i++) {
        for (j = 0; j < str2Length; j++) {
            if (str1[i] !== str2[j]) {
                num[i][j] = 0;
            } else {
                if (i === 0 || j === 0) {
                    num[i][j] = 1;
                } else {
                    num[i][j] = 1 + num[i - 1][j - 1];
                }

                if (num[i][j] > maxlen) {
                    maxlen = num[i][j];
                    thisSubsBegin = i - num[i][j] + 1;
                    if (lastSubsBegin === thisSubsBegin) {
                        sequence += str1[i];
                    } else {
                        lastSubsBegin = thisSubsBegin;
                        sequence = '';
                        sequence += str1.substr(lastSubsBegin, i + 1 - lastSubsBegin);
                    }
                }
            }
        }
    }
    return {
        length: maxlen,
        sequence: sequence,
        offset: thisSubsBegin,
    };
}

export function findBestLCS(mainItem, targetItems) {
    const results = [];
    let bestMatchIndex = 0;

    for (let i = 0; i < targetItems.length; i++) {
        const currentLCS = lcs(mainItem.name, targetItems[i].name);
        results.push({ target: targetItems[i], lcs: currentLCS });
        if (currentLCS.length > results[bestMatchIndex].lcs.length) {
            bestMatchIndex = i;
        }
    }

    const bestMatch = results[bestMatchIndex];

    return { allLCS: results, bestMatch: bestMatch, bestMatchIndex: bestMatchIndex };
}

export function delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export const getCookieArray = (cookies) => cookies.map(cookie => cookie.split(";")[0] + ";")
