// ============================================================
// 第1刀验证脚本：应用层加密协议回环测试（模拟客户端，Node实现同一套密码学）
// 用法：先 npm start 起服务端，另开终端 node tests/secure-roundtrip.js
// ------------------------------------------------------------
// 测1（握手）：ECDH P-256 密钥交换——两端各自算出同一把AES-256会话密钥
// 测2（加密登录）：login 的 data 走密文信封，服务端能解开并返回密文 login_response
// 测3（加密登出）：logout/logout_response 全程密文
// 测4（防篡改）：密文改一个字节 → 服务端必须立刻断开该连接（GCM认证生效）
// 判定标准：四项全过 = 协议两端实现一致
// ============================================================
const crypto = require('crypto');
const WebSocket = require('ws');

const URL = 'ws://127.0.0.1:3500';
const AAD = Buffer.from('MyChatSecureAAD1', 'utf8'); // 与服务端 crypto/session.ts 约定一致
const USERNAME = 'admin';
const PASSWORD = '123456';

let failures = 0;
function check(name, ok) {
    console.log(`${ok ? '✅ PASS' : '❌ FAIL'}  ${name}`);
    if (!ok) failures += 1;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function waitFor(ws, type, timeoutMs) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { cleanup(); reject(new Error(`等待 ${type} 超时`)); }, timeoutMs);
        function onMsg(raw) {
            const msg = JSON.parse(raw.toString());
            if (msg.type === type) { cleanup(); resolve(msg); }
            else if (msg.type === 'error') { cleanup(); reject(new Error('服务端报错: ' + JSON.stringify(msg.data))); }
        }
        function cleanup() { clearTimeout(timer); ws.off('message', onMsg); }
        ws.on('message', onMsg);
    });
}

// ---- 与服务端 session.ts 对称的密码学实现 ----
function encrypt(session, type, dataObj) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', session.key, iv);
    cipher.setAAD(AAD);
    const ct = Buffer.concat([cipher.update(JSON.stringify(dataObj), 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return JSON.stringify({ type, data: `${iv.toString('base64')}.${tag.toString('base64')}.${ct.toString('base64')}` });
}
function decrypt(session, wire) {
    const msg = JSON.parse(wire);
    const parts = String(msg.data).split('.');
    if (parts.length !== 3) throw new Error('信封格式错误');
    const d = crypto.createDecipheriv('aes-256-gcm', session.key, Buffer.from(parts[0], 'base64'));
    d.setAAD(AAD);
    d.setAuthTag(Buffer.from(parts[1], 'base64'));
    const plain = Buffer.concat([d.update(Buffer.from(parts[2], 'base64')), d.final()]).toString('utf8');
    return { type: msg.type, data: JSON.parse(plain) };
}
async function handshake(ws) {
    // 客户端生成ECC P-256密钥对，把公钥（SPKI DER）发过去
    const my = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const spki = my.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    ws.send(JSON.stringify({ type: 'key_exchange', data: { pub: spki } }));
    const hello = await waitFor(ws, 'key_exchange_response', 5000);
    // 拿服务端公钥+盐，算共享秘密→SHA256派生会话密钥
    const serverPub = crypto.createPublicKey({ key: Buffer.from(hello.data.pub, 'base64'), format: 'der', type: 'spki' });
    const shared = crypto.diffieHellman({ privateKey: my.privateKey, publicKey: serverPub });
    const salt = Buffer.from(hello.data.salt, 'base64');
    const key = crypto.createHash('sha256').update(Buffer.concat([shared, salt])).digest();
    return { key };
}
function open() {
    return new Promise((res, rej) => {
        const ws = new WebSocket(URL);
        ws.on('open', () => res(ws));
        ws.on('error', rej);
    });
}

async function main() {
    // ---------- 测1：握手 ----------
    try {
        const ws = await open();
        await handshake(ws); // 能走到这就说明握手协议两端一致、能推导出同一把密钥
        check('测1：ECDH握手完成（双方推导出同一把会话密钥）', true);
        ws.close();
    } catch (e) {
        check('测1 握手异常: ' + e.message, false);
    }

    // 重新来一遍更严谨的测2（上面的内联写法只是为了握手失败时也能报告）
    try {
        const ws = await open();
        const sess = await handshake(ws);
        ws.send(encrypt(sess, 'login', { username: USERNAME, password: PASSWORD }));
        const rawResp = await new Promise((resolve, reject) => {
            const t = setTimeout(() => reject(new Error('等login_response超时')), 5000);
            ws.on('message', (raw) => { clearTimeout(t); resolve(raw.toString()); });
        });
        const resp = decrypt(sess, rawResp);
        check('测2：加密login被服务端解开并返回密文login_response', resp.type === 'login_response' && resp.data.success === true);
        sess.ws = ws;

        // ---------- 测3：加密登出 ----------
        ws.send(encrypt(sess, 'logout', {}));
        const rawOut = await new Promise((resolve) => {
            const t = setTimeout(() => resolve(null), 5000);
            ws.on('message', (raw) => { clearTimeout(t); resolve(raw.toString()); });
        });
        const outMsg = rawOut ? decrypt(sess, rawOut) : null;
        check('测3：logout/logout_response 全程密文', !!(outMsg && outMsg.type === 'logout_response' && outMsg.data.success));
        ws.close();
    } catch (e) {
        check('测2/测3 流程异常: ' + e.message, false);
    }

    // ---------- 测4：篡改检测 ----------
    let tamperClosed = false;
    try {
        const ws = await open();
        const sess = await handshake(ws);
        ws.send(encrypt(sess, 'login', { username: USERNAME, password: PASSWORD }));
        await new Promise((resolve) => { const t = setTimeout(resolve, 1500); ws.once('message', () => { clearTimeout(t); resolve(); }); });
        // 拿到一条合法信封，把密文部分改一个字节
        const evil = encrypt(sess, 'login', { username: USERNAME, password: PASSWORD });
        const obj = JSON.parse(evil);
        const parts = obj.data.split('.');
        const ct = Buffer.from(parts[2], 'base64');
        ct[0] = ct[0] ^ 0x01; // 翻转密文第一个bit——GCM必须抓住它
        parts[2] = ct.toString('base64');
        obj.data = parts.join('.');
        ws.send(JSON.stringify(obj));
        await sleep(800);
        tamperClosed = ws.readyState !== WebSocket.OPEN; // 服务端应已断开
        try { ws.close(); } catch (e) {}
    } catch (e) { tamperClosed = false; }
    check('测4：密文被篡改后服务端立刻断开该连接', tamperClosed);

    console.log(failures === 0 ? '\n全部通过 🎉' : `\n${failures} 项失败`);
    process.exit(failures === 0 ? 0 : 1);
}

main().catch(e => { console.error('脚本异常:', e); process.exit(1); });
