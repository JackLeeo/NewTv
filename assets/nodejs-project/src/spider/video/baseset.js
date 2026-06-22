import CryptoJS from 'crypto-js';
import qr from 'qrcode';

function base64Decode(text) {
  return CryptoJS.enc.Utf8.stringify(CryptoJS.enc.Base64.parse(text));
}

function base64Encode(text) {
  return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(text));
}

async function init(inReq, outResp) {
  return {}
}


async function home(e, t) {
  return {
    class: [
      {
        type_id: 'setting',
        type_name: '配置'
      }
    ]
  }
}

async function category(e, t) {
  let r = e.body.id;
  let n = [];
  const proxyUrl = e.server.address().url + e.server.prefix + '/proxy';
  return {
    page: 1,
    pagecount: 1,
    limit: 1,
    total: 1,
    list: [{
      vod_id: 'website',
      vod_name: "扫码配置",
      vod_pic: proxyUrl + '/' + base64Encode(`${e.server.address().url}/website`)
    }]
  }
}

async function detail(e, t) {
  return {
    list: [{
      vod_name: '',
      vod_content: ''
    }]
  }
}

async function proxy(inReq, outResp) {
  const img = inReq.params.img;
  const text = base64Decode(img)
  const buffer = await qr.toBuffer(text, {width: 120, height: 120, margin: 15});
  outResp.send(buffer);
}

export default {
  meta: {
    key: 'baseset',
    name: '⚙️ 配置',
    type: 3,
  },
  api: async (fastify) => {
    fastify.post('/init', init);
    fastify.post('/home', home);
    fastify.post('/category', category);
    fastify.post('/detail', detail);
    fastify.get('/proxy/:img', proxy);
  },
};
