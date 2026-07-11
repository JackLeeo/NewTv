// **2026-07-09 临时关闭**: 调试期已结束, node.log 长期写会占用 Documents
// 缓存. 暂时停用, 代码保留, 需时把下方 [NODE_LOG_ENABLED] 改成 true 然后
// 重新跑 esbuild 重新打包 dist/main.js, 再走 iOS build 流程.
//
// **2026-07-08 node.log 诊断**: 启动时立刻解析 --node-log-path argv, 用
// require('fs') 同步追加 console.log/error + uncaughtException 到
// iOS Documents 沙盒 node.log. 必须在 require('http') / require('axios')
// 之前装好, 这样连 require 阶段抛错 / 静默 crash 都能记下 stack.
//
// fs 是 native POSIX, 不依赖 WASM/undici/fetch, iOS NodeMobile 可用.

// **总开关** - false 时整段 log 初始化跳过, console.log 走 OSLog 即可
// (swift --node-log-path 参数还会传过来, 但 src 不接, 等于无操作)
const NODE_LOG_ENABLED = false;

let nodeLogFile = null;
if (NODE_LOG_ENABLED) try {
    const fs = require('fs');
    const path = require('path');
    const logIdx = process.argv.indexOf('--node-log-path');
    const logPath = logIdx !== -1 ? process.argv[logIdx + 1] : null;
    if (logPath) {
        // 确保 runtime 目录存在 (Swift 端已建, 这里再保险一次)
        try { fs.mkdirSync(path.dirname(logPath), { recursive: true }); } catch (e) {}
        nodeLogFile = logPath;
        const util = require('util');
        const fmt = (args) => args.map(a => {
            if (typeof a === 'string') return a;
            if (a instanceof Error) return a.stack || a.message;
            try { return util.inspect(a); } catch (e) { return String(a); }
        }).join(' ');
        const writeLine = (level, args) => {
            const line = '[' + new Date().toISOString() + '] [' + level + '] ' + fmt(args) + '\n';
            try { fs.appendFileSync(nodeLogFile, line); } catch (e) {}
        };
        const origLog = console.log.bind(console);
        const origErr = console.error.bind(console);
        console.log = function () { writeLine('INFO', Array.from(arguments)); origLog.apply(null, arguments); };
        console.error = function () { writeLine('ERROR', Array.from(arguments)); origErr.apply(null, arguments); };
        // uncaughtException 立即写日志, 不调 exit (iOS embed library 进程死 = host 闪退)
        process.on('uncaughtException', function (err) {
            writeLine('FATAL_UNCAUGHT', [err && err.stack ? err.stack : (err && err.message ? err.message : String(err))]);
        });
        process.on('unhandledRejection', function (reason) {
            const r = reason && reason.stack ? reason.stack : (reason && reason.message ? reason.message : String(reason));
            writeLine('FATAL_UNHANDLED_REJECTION', [r]);
        });
        console.log('=== main.js boot start, pid=' + process.pid + ', argv=' + JSON.stringify(process.argv.slice(2)) + ' ===');
    }
} catch (e) {
    // fs 装不上就放弃, 走原 console.log
}
// NODE_LOG_ENABLED = false 时, 上面的 try { } catch (e) { } 整体不执行,
// nodeLogFile 保持 null, 后续所有 fs.appendFileSync 通过 (nodeLogFile || ...) 兜底,
// console.log 走 OSLog 即可 (iOS 上 OSLog 通过 Console.app 能看).

const { createServer } = require('http');
const axios = require('axios');
const { builtinModules } = require('module');

builtinModules.forEach(mod => {
    if (!['trace_events'].includes(mod)) {
        globalThis[mod] = require(mod);
    }
});
console.log('=== main.js after builtinModules.forEach, nativeServerPort=0 (will be set later) ===');

let addon = null;
let sourceModule = null;
let nativeServerPort = 0;
let managementPort = 0;
let spiderPort = 0;
let isReady = false;

try {
    addon = process._linkedBinding('myaddon');
} catch (e) {
    addon = null;
}

const nativePortIdx = process.argv.indexOf('--native-port');
if (nativePortIdx !== -1 && process.argv[nativePortIdx + 1]) {
    nativeServerPort = parseInt(process.argv[nativePortIdx + 1], 10);
}
console.log('=== main.js nativeServerPort resolved: ' + nativeServerPort + ' ===');

globalThis.catServerFactory = (handle) => {
    let port = 0;
    const server = createServer((req, res) => {
        handle(req, res);
    });
    server.on('listening', () => {
        port = server.address().port;
        spiderPort = port;
        if (nativeServerPort > 0) {
            axios.get(`http://127.0.0.1:${nativeServerPort}/onCatPawOpenPort?port=${port}&type=spider`).catch(() => {});
        }
        console.log('Spider server running on ' + port);
    });
    server.on('close', () => {
        console.log('Spider server closed on ' + port);
    });
    return server;
};

globalThis.catDartServerPort = () => nativeServerPort;

function loadScript(path) {
    console.log('loadScript called with path:', path);
    const indexJSPath = path + '/index.js';
    const indexConfigJSPath = path + '/index.config.js';

    try {
        delete require.cache[require.resolve(indexJSPath)];
    } catch (e) {}

    try {
        delete require.cache[require.resolve(indexConfigJSPath)];
    } catch (e) {}

    try {
        sourceModule = require(indexJSPath);
        console.log('index.js loaded successfully');
    } catch (e) {
        console.error('ERROR loading index.js:', e.message);
        throw e;
    }

    let config = {};
    try {
        const configModule = require(indexConfigJSPath);
        config = configModule.default || configModule;
        console.log('Config loaded');
    } catch (e) {
        console.log('Config load skipped:', e.message);
    }

    try {
        const result = sourceModule.start(config);
        if (result && typeof result.then === 'function') {
            result.catch(e => console.error('ERROR in sourceModule.start() async:', e.message));
        }
        console.log('sourceModule.start(config) initiated');
    } catch (e) {
        console.error('ERROR in sourceModule.start(config):', e.message);
        throw e;
    }
}

function sendMessageToNative(message) {
    if (addon && addon.sendMessageToNative) {
        try {
            addon.sendMessageToNative(message);
            return;
        } catch (e) {}
    }
    if (nativeServerPort > 0) {
        axios.post(`http://127.0.0.1:${nativeServerPort}/onMessage`, { message: message }).catch(() => {});
    }
}

function handleNativeMessage(msg) {
    try {
        const data = JSON.parse(msg);
        switch (data.action) {
            case 'run':
                try {
                    if (sourceModule && typeof sourceModule.stop === 'function') {
                        sourceModule.stop();
                    }
                } catch (e) {}
                spiderPort = 0;
                loadScript(data.path);
                break;
            case 'nativeServerPort':
                nativeServerPort = data.port;
                break;
            default:
                break;
        }
    } catch (e) {
        console.log('handleNativeMessage error:', e);
    }
}

if (addon && addon.registerCallback) {
    addon.registerCallback((msg) => {
        handleNativeMessage(msg);
    });
}

const mgmtServer = createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    const url = new URL(req.url, `http://127.0.0.1`);

    if (req.method === 'GET' && url.pathname === '/check') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ run: true, ready: isReady }));
        return;
    }

    if (req.method === 'GET' && url.pathname === '/source/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            sourceLoaded: sourceModule !== null,
            spiderPort: spiderPort,
            ready: isReady,
        }));
        return;
    }

    if (req.method === 'POST' && url.pathname === '/source/loadPath') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const sourcePath = data.path;

                if (!sourcePath) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'path is required' }));
                    return;
                }

                try {
                    if (sourceModule && typeof sourceModule.stop === 'function') {
                        sourceModule.stop();
                    }
                } catch (e) {}

                spiderPort = 0;
                loadScript(sourcePath);

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true, message: 'Source loaded from path' }));
            } catch (e) {
                console.error('ERROR in /source/loadPath:', e.message);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }

    if (req.method === 'POST' && url.pathname === '/command') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                handleNativeMessage(JSON.stringify(data));
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
});

mgmtServer.listen(0, '127.0.0.1', () => {
    managementPort = mgmtServer.address().port;
    console.log('=== mgmtServer listening on port ' + managementPort + ', nativeServerPort=' + nativeServerPort + ' ===');
    if (nativeServerPort > 0) {
        axios.get(`http://127.0.0.1:${nativeServerPort}/onCatPawOpenPort?port=${managementPort}&type=management`)
            .then(() => console.log('=== onCatPawOpenPort(mgmt) sent OK ==='))
            .catch((e) => console.error('=== onCatPawOpenPort(mgmt) FAIL: ' + (e && e.message ? e.message : e) + ' ==='));
    }
    isReady = true;
    console.log('=== before sendMessageToNative(ready) ===');
    sendMessageToNative('ready');
    console.log('=== after sendMessageToNative(ready) ===');
});

process.on('uncaughtException', function (err) {
    console.error('Caught exception:', err);
});
