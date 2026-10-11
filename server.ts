import { WebSocketServer , WebSocket } from 'ws'
import {IncomingMessage, OutgoingMessage, ClientContext} from './handlers/types'
import * as auth from './handlers/auth'
import * as message from './handlers/message'
import * as friend from './handlers/friend'
import * as group from './handlers/group'
import * as userStore from './store/users'
import * as groupStore from './store/groups'
import * as messageStore from './store/messages'
import { SessionCrypto } from './crypto/session'

userStore.loadUsers()
groupStore.loadGroups()
messageStore.loadMessages()

const clientMap = new Map<string, WebSocket>();
// 安全加固#7：每条连接的加密会话——key_exchange握手成功后才有一条
const sessions = new Map<WebSocket, SessionCrypto>();

// 统一出站口：有会话的连接一律加密后再发，没有会话（握手前）按明文发。
// 所有发给客户端的消息都必须走这里——漏掉一个出口就是一处明文泄漏
function sendTo(ws: WebSocket, msg: OutgoingMessage){
    const sess = sessions.get(ws);
    const wire = sess ? sess.encryptMsg(msg) : msg;
    try {
        ws.send(JSON.stringify(wire));
    } catch (e) { /* 对端可能已断开，发不进就算了 */ }
}

function broadcastTo(userId: string, msg: OutgoingMessage){
    const ws = clientMap.get(userId);
    if(ws){
        sendTo(ws, msg);
    }
}

function isUserOnline(userId: string): boolean {
    return clientMap.has(userId);
}

// Bug7修复：登录失败限速（滑动窗口）
// key = ${username}:${ip标识}；值 = {firstFailTime, failures}
interface RateLimitEntry { firstFailTime: number; failures: number; }
const loginRateLimit = new Map<string, RateLimitEntry>();
const RATE_WINDOW_MS = 60 * 1000;   // 60秒窗口
const RATE_MAX_FAILURES = 10;       // 最多10次失败

function isLoginRateLimited(key: string): boolean {
    const now = Date.now();
    const entry = loginRateLimit.get(key);
    if (!entry) return false;
    if (now - entry.firstFailTime > RATE_WINDOW_MS) {
        loginRateLimit.delete(key);
        return false;
    }
    return entry.failures >= RATE_MAX_FAILURES;
}
function recordLoginFailure(key: string): void {
    const now = Date.now();
    const entry = loginRateLimit.get(key);
    if (!entry || now - entry.firstFailTime > RATE_WINDOW_MS) {
        loginRateLimit.set(key, { firstFailTime: now, failures: 1 });
        return;
    }
    entry.failures += 1;
}
function recordLoginSuccess(key: string): void {
    loginRateLimit.delete(key);
}

// 从ws对象上取一个稳定的ip标识（没有就用unknown）
function getWsIp(ws: WebSocket & { _socket?: { remoteAddress?: string } }): string {
    try {
        const anyWs = ws as any;
        if (anyWs._socket && anyWs._socket.remoteAddress) return anyWs._socket.remoteAddress;
        if (anyWs.socket && anyWs.socket.remoteAddress) return anyWs.socket.remoteAddress;
    } catch (_) { /* ignore */ }
    return 'unknown';
}

// 安全加固#2：心跳——每30秒ping一轮，连续两轮（60秒）没回pong就判死强拆
// 为什么需要：模拟器休眠/强杀App这类"半开连接"永远不会触发close事件，
// 没有心跳的话，僵尸连接会一直占着clientMap里的在线名额，顶号/在线状态全乱
const HEARTBEAT_INTERVAL_MS = 30 * 1000;

const wss = new WebSocketServer({ port: 3500 });

// 安全加固#1（服务器级）：端口被占用这类错误以前没人监听，会作为未捕获异常把进程打崩
wss.on('error', (err) => {
    console.error('[服务器错误]', err);
});

wss.on('connection', (ws: WebSocket) => {
    const ctx: ClientContext = {
        userId: null,
        ws: ws,
    };
    // 心跳定时器只拿得到ws对象，把ctx反挂在ws上它才能读到isAlive
    (ws as any).ctx = ctx;
    ctx.isAlive = true;
    // 客户端每回一个pong，就重新点亮"还活着"标记
    ws.on('pong', () => { ctx.isAlive = true; });
    const ip = getWsIp(ws as any);

    // 安全加固#1（连接级）：必须监听error——ws库遇到畸形帧/无效UTF-8会emit('error')，
    // 没人监听时Node把它当未捕获异常直接把整个进程打崩。
    // 这就是"后端明明开着却连不上"的头号元凶：进程早死了，重启之后才"又能连上"
    ws.on('error', (err) => {
        console.error('[连接错误]', err);
        try { ws.close(); } catch (_) { /* 连接已经坏了，优雅关闭失败就随它去 */ }
    });

    ws.on('message', (rawData: any) => { 
        try{
        // Bug8修复：ws库也会传Buffer/ArrayBuffer，不是一定string
        let data: string;
        if (typeof rawData === 'string') {
            data = rawData;
        } else if (rawData instanceof Buffer) {
            data = rawData.toString('utf-8');
        } else if (typeof (rawData as any).toString === 'function') {
            data = (rawData as any).toString('utf-8');
        } else {
            sendTo(ws, {type: 'error', data: {code: 400, message: '消息格式错误'}});
            return;
        }

        const msg: IncomingMessage = JSON.parse(data);
        let result: OutgoingMessage[] = [];

        // 安全加固#7（入站）：已握手的连接，data字段是密文信封，先解再分发。
        // GCM校验不过 = 密文被篡改或密钥错位，这种连接不能再信，直接断
        const sess = sessions.get(ws);
        if (sess && msg.type !== 'key_exchange') {
            try {
                msg.data = sess.decryptData(msg.data);
            } catch (e) {
                console.error('[会话] 解密失败，断开该连接', e);
                try { ws.close(); } catch (_) { /* ignore */ }
                return;
            }
        }

        // 安全加固#5：登出协议——以前服务端根本不认识logout消息，
        // 前端退出登录只能靠掐断TCP，服务端全靠close事件善后；
        // 半开连接下close不来，旧账号就一直"假在线"。现在显式登出：清映射→回执→关连接
        // （logout要动clientMap和连接本身，这俩都是server.ts的私产，所以不拆去handlers）
        if (msg.type === 'logout') {
            if (ctx.userId && clientMap.get(ctx.userId) === ws) {
                clientMap.delete(ctx.userId);
            }
            ctx.userId = null;
            sendTo(ws, { type: 'logout_response', data: { success: true } });
            try { ws.close(); } catch (_) { /* 忽略 */ }
            return;
        }

        // 安全加固#7（握手）：客户端连上后的第一件事——发来它的ECC公钥。
        // 服务端回自己的公钥+随机盐，两边各自算出同一把AES会话密钥，此后data全走密文
        if (msg.type === 'key_exchange') {
            const pubB64 = (msg.data && typeof msg.data.pub === 'string') ? msg.data.pub : '';
            try {
                const hello = SessionCrypto.establish(pubB64);
                // 回执必须明文发（此刻会话还没注册），发完立刻注册——之后的收发全走密文
                ctx.ws.send(JSON.stringify({ type: 'key_exchange_response', data: hello.response }));
                sessions.set(ws, hello.session);
                console.log('[会话] 加密握手完成');
            } catch (e) {
                console.error('[会话] 握手失败（公钥无效？）', e);
                sendTo(ws, { type: 'error', data: { code: 400, message: '握手失败' } });
            }
            return;
        }

        // Bug7：登录限速（login和register都基于用户名+ip）
        // 安全加固#3：记下这条连接登录前的旧身份——同一条socket换账号登录时要用它清理悬挂条目
        const prevUserId = ctx.userId;

        if (msg.type === 'login' || msg.type === 'register') {
            const uname = String(((msg.data && msg.data.username) ?? '')).slice(0, 64) || '_';
            const rateKey = `${uname}:${ip}`;
            if (isLoginRateLimited(rateKey)) {
                sendTo(ws, {
                    type: msg.type === 'login' ? 'login_response' : 'register_response',
                    data: { success: false, error: '尝试过于频繁，请稍后再试' }
                });
                return;
            }
            switch(msg.type){
                case 'login':
                    result = auth.handleLogin(msg, ctx);
                    break;
                case 'register':
                    result = auth.handleRegister(msg, ctx);
                    break;
            }
            // 记录失败/成功
            const resp = result[0] && result[0].data;
            if (resp && resp.success === false) {
                // 安全加固#6：只有"用户名密码都带齐、真的凭据被拒"才烧限速额度——
                // 以前缺字段的失败也计数，前端自动重试几次就能把额度烧光，
                // 之后连正确的密码也会被"尝试过于频繁"拒之门外（"有时登不上"的来源之一）
                const hasCreds = !!(msg.data && msg.data.username && msg.data.password);
                if (hasCreds) {
                    recordLoginFailure(rateKey);
                }
            } else if (resp && resp.success === true) {
                recordLoginSuccess(rateKey);
            }
        } else {
            switch(msg.type){
                case 'friend_search':
                    result = friend.handleFriendSearch(msg, ctx);
                    break;
                case 'friend_request':
                    result = friend.handleFriendRequest(msg, ctx, broadcastTo);
                    break;
                case 'friend_respond':
                    result = friend.handleFriendRespond(msg, ctx, broadcastTo);
                    break;
                case 'delete_friend':
                    result = friend.handleDeleteFriend(msg, ctx, broadcastTo);
                    break;
                case 'create_group':
                    result = group.handleCreateGroup(msg, ctx, broadcastTo);
                    break;
                case 'group_search':
                    result = group.handleGroupSearch(msg, ctx);
                    break;
                case 'group_join_request':
                    result = group.handleGroupJoinRequest(msg, ctx, broadcastTo);
                    break;
                case 'group_join_respond':
                    result = group.handleGroupJoinRespond(msg, ctx, broadcastTo);
                    break;
                case 'group_invite':
                    result = group.handleGroupInvite(msg, ctx, broadcastTo);
                    break;
                case 'group_leave':
                    result = group.handleGroupLeave(msg, ctx, broadcastTo);
                    break;
                case 'group_dissolve':
                    result = group.handleGroupDissolve(msg, ctx, broadcastTo);
                    break;
                case 'group_members':
                    result = group.handleGroupMembers(msg, ctx);
                    break;
                case 'group_kick':
                    result = group.handleGroupKick(msg, ctx, broadcastTo);
                    break;
                case 'private_chat':
                    result = message.handlePrivateMessage(msg, ctx, broadcastTo);
                    break;
                case 'group_chat':
                    result = message.handleGroupChat(msg, ctx, broadcastTo);
                    break;
                case 'group_private':
                    result = message.handleGroupPrivate(msg, ctx, broadcastTo);
                    break;
                case 'history_request':
                    result = message.handleHistoryRequest(msg, ctx);
                    break;
                case 'mark_read':
                    result = message.handleMarkRead(msg, ctx);
                    break;
                default:
                    result = [{type: 'error', data: {code: 400, message: '未知消息类型'}}];
            }
        }

        // 先注册 clientMap，再发送 result，确保 broadcastTo 能找到当前用户
        // （否则好友请求、群邀请等广播消息会丢失）
        if((msg.type === 'login' || msg.type === 'register' ) && ctx.userId){
            // 安全加固#3：同一条socket换账号登录，先删掉旧账号的映射条目——
            // 不删的话条目永久悬挂，旧账号以后在别处登录时，顶号逻辑会误把这个socket关掉
            if(prevUserId && prevUserId !== ctx.userId && clientMap.get(prevUserId) === ws){
                clientMap.delete(prevUserId);
            }
            const oldWs = clientMap.get(ctx.userId);
            if(oldWs && oldWs !== ws){
                // 安全加固#4：顶号前先发一条kicked再关——被踢端要靠它提示用户、拦停自动重连；
                // 不打招呼直接close，被踢端只会没头没脑地重连再被踢，来回踢皮球
                sendTo(oldWs, { type: 'kicked', data: { reason: '账号在其他设备登录' } }); // 旧连接有会话就密文，没有就明文；sendTo内部已兜发送异常
                try { oldWs.close(); } catch(e) { /* 忽略关闭异常 */ }
            }
            clientMap.set(ctx.userId, ws);
        }
        for(const r of result){
            sendTo(ws, r);
        }
    } catch(e){
        try { console.log(e); } catch(_) { /* ignore */ }
        try {
            sendTo(ws, {type: 'error', data: {code: 400, message: '消息格式错误'}});
        } catch(_) { /* ignore */ }
    }
    });

    ws.on('close', () => { 
        if(ctx.userId && clientMap.get(ctx.userId) === ws){
            clientMap.delete(ctx.userId);
        }     
    });

});

// 安全加固#2：心跳总开关——每30秒对所有连接点名一次：
// isAlive还是false = 上一轮ping没回 = 连着两轮失联 = 判死，terminate()强拆
// （terminate比close狠：不等关闭握手直接掐TCP，专治装死的连接）
const heartbeatTimer = setInterval(() => {
    wss.clients.forEach((client) => {
        const c = (client as any).ctx as ClientContext | undefined;
        if (!c || !c.isAlive) {
            try { client.terminate(); } catch (_) { /* ignore */ }
            return;
        }
        c.isAlive = false;
        try { client.ping(); } catch (_) { /* ignore */ }
    });
}, HEARTBEAT_INTERVAL_MS);
wss.on('close', () => clearInterval(heartbeatTimer));

console.log('服务器启动，端口 3500');
