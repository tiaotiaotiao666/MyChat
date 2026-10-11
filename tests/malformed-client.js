// ============================================================
// 第0刀验证脚本：服务端健壮性三项测试
// 用法：先 npm start 起服务端，另开终端 node tests/malformed-client.js
// ------------------------------------------------------------
// 测1（畸形帧）：握手成功后手工发一个"保留opcode"的畸形WS帧——
//   以前服务端没挂 error 监听，这一下整个进程直接崩；现在应该只断这条连接
// 测2（顶号）：同一账号连两条WS，后登的把先登的顶掉——先登的那条必须收到 kicked
// 测3（登出）：logout 消息必须得到 logout_response（以前服务端根本不认识这个类型）
// 判定标准：三项全过 = 服务端活着且行为正确（脚本最后打印 PASS/FAIL）
// ============================================================
const net = require('net');
const crypto = require('crypto');
const WebSocket = require('ws');

const URL = 'ws://127.0.0.1:3500';
const PORT = 3500;
const USERNAME = 'admin';     // data/users.json 里的遗留账号（123456），只用来做连通性验证
const PASSWORD = '123456';

let failures = 0;
function check(name, ok) {
    console.log(`${ok ? '✅ PASS' : '❌ FAIL'}  ${name}`);
    if (!ok) failures += 1;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// 生成一段"手工构造"的畸形帧：FIN+保留opcode 0x3，带掩码（客户端帧必须掩码，格式本身合法，
// 但 opcode 3 是协议保留值，ws 库必须报协议错误 → 走 error 事件 → 这正是以前崩进程的路径）
function malformedFrame() {
    return Buffer.from([0x83, 0x80, 0, 0, 0, 0]); // 0x83=FIN+opcode3, 0x80=masked, 4字节空掩码
}

function httpHandshake(socket) {
    const key = crypto.randomBytes(16).toString('base64');
    socket.write(
        'GET / HTTP/1.1\r\n' +
        `Sec-WebSocket-Key: ${key}\r\n` +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        'Sec-WebSocket-Version: 13\r\n' +
        '\r\n'
    );
}

// 等一条 ws 连接收到指定 type 的消息（超时返回 null）
function waitFor(ws, type, timeoutMs) {
    return new Promise((resolve) => {
        const timer = setTimeout(() => { cleanup(); resolve(null); }, timeoutMs);
        function onMsg(raw) {
            const msg = JSON.parse(raw.toString());
            if (msg.type === type) { cleanup(); resolve(msg); }
        }
        function cleanup() { clearTimeout(timer); ws.off('message', onMsg); }
        ws.on('message', onMsg);
    });
}

function login(ws) {
    return new Promise((resolve, reject) => {
        ws.send(JSON.stringify({ type: 'login', data: { username: USERNAME, password: PASSWORD } }));
        waitFor(ws, 'login_response', 5000).then(resp => {
            if (resp && resp.data && resp.data.success) resolve(resp.data);
            else reject(new Error('登录被拒: ' + JSON.stringify(resp)));
        });
    });
}

async function main() {
    // ---------- 测1：畸形帧 ----------
    await new Promise((resolve) => {
        const socket = net.connect(PORT, '127.0.0.1', () => httpHandshake(socket));
        socket.on('data', (chunk) => {
            if (chunk.toString().includes('101')) {
                // 握手完成，甩畸形帧过去
                socket.write(malformedFrame());
                setTimeout(() => { socket.destroy(); resolve(); }, 500);
            }
        });
        socket.on('error', () => resolve());
    });
    await sleep(300);

    // 服务端必须还活着：正常客户端能完成登录全流程
    let alive = false;
    try {
        const probe = new WebSocket(URL);
        await new Promise((res, rej) => { probe.on('open', res); probe.on('error', rej); });
        await login(probe);
        probe.close();
        alive = true;
    } catch (e) { alive = false; }
    check('测1：畸形帧后服务端存活并能正常登录', alive);

    // ---------- 测2：顶号通知 ----------
    let kickedReceived = false;
    try {
        const wsA = new WebSocket(URL);
        await new Promise((res, rej) => { wsA.on('open', res); wsA.on('error', rej); });
        await login(wsA);
        wsA.on('message', (raw) => {
            const msg = JSON.parse(raw.toString());
            if (msg.type === 'kicked') kickedReceived = true;
        });

        const wsB = new WebSocket(URL);
        await new Promise((res, rej) => { wsB.on('open', res); wsB.on('error', rej); });
        await login(wsB); // 同账号第二处登录 → 应顶掉 wsA

        await sleep(800); // 给 kicked 消息留到达时间
        check('测2：顶号时旧连接收到 kicked 通知', kickedReceived);
        wsA.close(); wsB.close();
    } catch (e) {
        check('测2：顶号时旧连接收到 kicked 通知（流程异常: ' + e.message + '）', false);
    }

    // ---------- 测3：登出协议 ----------
    let logoutOk = false;
    try {
        const wsC = new WebSocket(URL);
        await new Promise((res, rej) => { wsC.on('open', res); wsC.on('error', rej); });
        await login(wsC);
        const resp = await Promise.race([
            new Promise((resolve) => {
                wsC.on('message', (raw) => {
                    const msg = JSON.parse(raw.toString());
                    if (msg.type === 'logout_response') resolve(msg);
                });
                wsC.send(JSON.stringify({ type: 'logout', data: {} }));
            }),
            sleep(3000).then(() => null)
        ]);
        logoutOk = !!(resp && resp.data && resp.data.success);
        wsC.close();
    } catch (e) { logoutOk = false; }
    check('测3：logout 得到 logout_response 回执', logoutOk);

    console.log(failures === 0 ? '\n全部通过 🎉' : `\n${failures} 项失败`);
    process.exit(failures === 0 ? 0 : 1);
}

main().catch(e => { console.error('脚本异常:', e); process.exit(1); });
