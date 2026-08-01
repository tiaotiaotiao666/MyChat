import { WebSocketServer , WebSocket } from 'ws'
import {IncomingMessage, OutgoingMessage, ClientContext} from './handlers/types'
import * as auth from './handlers/auth'
import * as message from './handlers/message'
import * as friend from './handlers/friend'
import * as group from './handlers/group'
import * as userStore from './store/users'
import * as groupStore from './store/groups'
import * as messageStore from './store/messages'

userStore.loadUsers()
groupStore.loadGroups()
messageStore.loadMessages()

const clientMap = new Map<string, WebSocket>();

function broadcastTo(userId: string, msg: OutgoingMessage){
    const ws = clientMap.get(userId);
    if(ws){
        ws.send(JSON.stringify(msg));
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

const wss = new WebSocketServer({ port: 3500 });
wss.on('connection', (ws: WebSocket) => { 
    const ctx: ClientContext = {
        userId: null,
        ws: ws,
    };
    const ip = getWsIp(ws as any);

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
            ctx.ws.send(JSON.stringify({type: 'error', data: {code: 400, message: '消息格式错误'}}));
            return;
        }

        const msg: IncomingMessage = JSON.parse(data);
        let result: OutgoingMessage[] = [];

        // Bug7：登录限速（login和register都基于用户名+ip）
        if (msg.type === 'login' || msg.type === 'register') {
            const uname = String(((msg.data && msg.data.username) ?? '')).slice(0, 64) || '_';
            const rateKey = `${uname}:${ip}`;
            if (isLoginRateLimited(rateKey)) {
                ctx.ws.send(JSON.stringify({
                    type: msg.type === 'login' ? 'login_response' : 'register_response',
                    data: { success: false, error: '尝试过于频繁，请稍后再试' }
                }));
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
                recordLoginFailure(rateKey);
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
            const oldWs = clientMap.get(ctx.userId);
            if(oldWs && oldWs !== ws){
                try { oldWs.close(); } catch(e) { /* 忽略关闭异常 */ }
            }
            clientMap.set(ctx.userId, ws);
        }
        for(const r of result){
            ctx.ws.send(JSON.stringify(r));
        }
    } catch(e){
        try { console.log(e); } catch(_) { /* ignore */ }
        try {
            ctx.ws.send(JSON.stringify({type: 'error', data: {code: 400, message: '消息格式错误'}}));
        } catch(_) { /* ignore */ }
    }
    });

    ws.on('close', () => { 
        if(ctx.userId && clientMap.get(ctx.userId) === ws){
            clientMap.delete(ctx.userId);
        }     
    });

});

console.log('服务器启动，端口 3500');
