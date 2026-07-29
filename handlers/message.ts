import { IncomingMessage, OutgoingMessage, ClientContext } from './types'
import * as userStore from '../store/users'
import * as messageStore from '../store/messages'
import * as groupStore from '../store/groups'

export function handlePrivateMessage(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
        if(!ctx.userId){
            result.push({
                type: 'error',
                data: {
                    code: 401,
                    message: '未登录'
                }
            });
            return result;
        }
    const targetUserId = msg.data.targetUserId as string;
    const content = msg.data.content as string;
    const fromUser = userStore.findByUserId(ctx.userId);
    const toUser = userStore.findByUserId(targetUserId);
    if(!fromUser || !toUser){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户不存在'
            }
        });
        return result;
    }
    if(!fromUser.friends.includes(toUser.userId)){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '只能给好友发消息'
            }
        });
        return result;
    }
    const msg_saved = messageStore.savePrivateMessage(ctx.userId, targetUserId, content);
    broadcastTo(targetUserId, {
        type: 'private_chat',
        data: {
            senderId: fromUser.userId,
            senderNickname: fromUser.nickname,
            senderAvatar: fromUser.avatar,
            content: msg_saved.content,
            timestamp: msg_saved.timestamp
        }
    });
    result.push({type: 'system', data: {text: '发送成功'}})
    return result;
}

export function handleGroupChat(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void){
    const result: OutgoingMessage[] = [];
        if(!ctx.userId){
            result.push({
                type: 'error',
                data: {
                    code: 401,
                    message: '未登录'
                }
            });
            return result;
        }
    const groupId = msg.data.groupId as string;
    const content = msg.data.content as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if(!group.members.includes(ctx.userId)){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '不是群组成员'
            }
        });
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const msg_saved = messageStore.saveGroupMessage(ctx.userId, groupId, content);
    for(const memberId of group.members){
        if(memberId !== ctx.userId){
            broadcastTo(memberId, {
                type: 'group_chat',
                data: {
                    senderId: ctx.userId,
                    senderNickname: fromUser?.nickname || '',
                    senderAvatar: fromUser?.avatar || '',
                    groupId,
                    content: msg_saved.content,
                    timestamp: msg_saved.timestamp,
                }
            })
        }
    }
    result.push({type: 'system', data: {text: '发送成功'}})
    return result;
}

export function handleGroupPrivate(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void){
    const result: OutgoingMessage[] = [];
        if(!ctx.userId){
            result.push({
                type: 'error',
                data: {
                    code: 401,
                    message: '未登录'
                }
            });
            return result;
        }
    const groupId = msg.data.groupId as string;
    const content = msg.data.content as string;
    const group = groupStore.findByGroupId(groupId);
    const targetUserId = msg.data.targetUserId as string;
    if(!group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if(!group.members.includes(ctx.userId)){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '不是群组成员'
            }
        });
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const msg_saved = messageStore.saveGroupMessage(ctx.userId, groupId, content,targetUserId);
    broadcastTo(targetUserId, {
        type: 'group_private',
        data: {
            senderId: ctx.userId,
            senderNickname: fromUser?.nickname || '',
            senderAvatar: fromUser?.avatar || '',
            groupId,
            content: msg_saved.content,
            timestamp: msg_saved.timestamp,
        }
    })
    result.push({type: 'system', data: {text: '发送成功'}})
    return result;
}

export function handleHistoryRequest(msg: IncomingMessage, ctx: ClientContext){
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const type = msg.data.type as 'private' | 'group' ;
    const targetId = msg.data.targetId as string;
    const count = msg.data.count as number || 50;
    let messages;
    if(type === 'private'){
        messages = messageStore.getPrivateHistory(ctx.userId, targetId, count);
    }else{
        messages = messageStore.getGroupHistory(targetId, count);
    }
    result.push({
        type: 'history_response',
        data: {messages}
    });
    return result;
}