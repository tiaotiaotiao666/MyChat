import { WebSocketServer , WebSocket } from 'ws'
import {IncomingMessage, OutgoingMessage, ClientContext} from './handlers/types'
import * as auth from './handlers/auth'
import * as message from './handlers/message'
import * as friend from './handlers/friend'
import * as group from './handlers/group'

const clientMap = new Map<string, WebSocket>();

function broadcastTo(userId: string, msg: OutgoingMessage){
    const ws = clientMap.get(userId);
    if(ws){
        ws.send(JSON.stringify(msg));
    }
}

const wss = new WebSocketServer({ port: 3500 });
wss.on('connection', (ws: WebSocket) => { 
    const ctx: ClientContext = {
        userId: null,
        ws: ws,
    };

    ws.on('message', (data: string) => { 
        try{
        const msg: IncomingMessage = JSON.parse(data);
        let result: OutgoingMessage[] = [];
        switch(msg.type){
            case 'register':
                result = auth.handleRegister(msg, ctx);
                break;
            case 'login':
                result = auth.handleLogin(msg, ctx);
                break;
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
            default:
                result = [{type: 'error', data: {code: 400, message: '未知消息类型'}}];
        }
        for(const r of result){
            ctx.ws.send(JSON.stringify(r));
        }
        if((msg.type === 'login' || msg.type === 'register' ) && ctx.userId){
            clientMap.set(ctx.userId, ws);
        }
    } catch(e){
        console.log(e);
        ctx.ws.send(JSON.stringify({type: 'error', data: {code: 400, message: '消息格式错误'}}));
    }
    });

    ws.on('close', () => { 
        if(ctx.userId){
            clientMap.delete(ctx.userId);
        }     
    });

});

console.log('服务器启动，端口 3500');