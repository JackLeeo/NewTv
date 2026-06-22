const { createServer } = require('http');
const axios = require('axios');
const { builtinModules } = require('module');

builtinModules.forEach(mod => {
    if (!['trace_events'].includes(mod)) {
        globalThis[mod] = require(mod);
    }
});

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
    if (nativeServerPort > 0) {
        axios.get(`http://127.0.0.1:${nativeServerPort}/onCatPawOpenPort?port=${managementPort}&type=management`).catch(() => {});
    }
    isReady = true;
    sendMessageToNative('ready');
});

process.on('uncaughtException', function (err) {
    console.error('Caught exception:', err);
});
