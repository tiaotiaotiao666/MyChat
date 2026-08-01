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
    // BUG#6：私聊消息 content 非空校验（防止用户发送空消息）
    if (typeof content !== 'string' || content.trim() === '') {
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '消息内容不能为空'
            }
        });
        return result;
    }
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
    const msg_saved = messageStore.savePrivateMessage(ctx.userId, fromUser.username, fromUser.avatar, targetUserId, content);
    broadcastTo(targetUserId, {
        type: 'private_chat',
        data: {
            senderId: fromUser.userId,
            senderUsername: fromUser.username,
            senderAvatar: fromUser.avatar,
            content: msg_saved.content,
            timestamp: msg_saved.timestamp
        }
    });
    userStore.incrementUnread(targetUserId, ctx.userId);
    result.push({type: 'private_chat_sent', data: {messageId: msg_saved.messageId, content: msg_saved.content, timestamp: msg_saved.timestamp, targetUserId}})
    return result;
}

export function handleGroupChat(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
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
    // BUG#6：群聊消息 content 非空校验（防止用户发送空消息）
    if (typeof content !== 'string' || content.trim() === '') {
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '消息内容不能为空'
            }
        });
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const msg_saved = messageStore.saveGroupMessage(ctx.userId, fromUser?.username || '', fromUser?.avatar || '', groupId, content);
    for(const memberId of group.members){
        if(memberId !== ctx.userId){
            broadcastTo(memberId, {
                type: 'group_chat',
                data: {
                    senderId: ctx.userId,
                    senderUsername: fromUser?.username || '',
                    senderAvatar: fromUser?.avatar || '',
                    groupId,
                    content: msg_saved.content,
                    timestamp: msg_saved.timestamp,
                }
            })
            userStore.incrementUnread(memberId, groupId);
        }
    }
    result.push({type: 'group_chat_sent', data: {messageId: msg_saved.messageId, content: msg_saved.content, timestamp: msg_saved.timestamp, groupId}})
    return result;
}

export function handleGroupPrivate(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
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
    if(!group.members.includes(targetUserId)){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '目标用户不是群组成员'
            }
        });
        return result;
    }
    // BUG#6：群内私聊消息 content 非空校验
    if (typeof content !== 'string' || content.trim() === '') {
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '私聊内容不能为空'
            }
        });
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const msg_saved = messageStore.saveGroupMessage(ctx.userId, fromUser?.username || '', fromUser?.avatar || '', groupId, content, targetUserId);
    broadcastTo(targetUserId, {
        type: 'group_private',
        data: {
            senderId: ctx.userId,
            senderUsername: fromUser?.username || '',
            senderAvatar: fromUser?.avatar || '',
            groupId,
            content: msg_saved.content,
            timestamp: msg_saved.timestamp,
        }
    })
    userStore.incrementUnread(targetUserId, groupId);
    result.push({type: 'group_private_sent', data: {messageId: msg_saved.messageId, content: msg_saved.content, timestamp: msg_saved.timestamp, groupId}})
    return result;
}

export function handleMarkRead(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const targetId = msg.data.targetId as string;
    userStore.clearUnread(ctx.userId, targetId);
    return result;
}

export function handleHistoryRequest(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
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
    // BUG#2：count=0 明确传0时不应被 || 回退成 50，改用空值合并运算符
    const count = (msg.data.count as number) ?? 50;
    let messages;
    if(type === 'private'){
        // 🟢 BUG#3 修复：拉私聊历史前先验证双方是否仍为好友，防止删除好友后仍能通过 history_request 拉取聊天记录
        const curUser = userStore.findByUserId(ctx.userId);
        if (!curUser || !curUser.friends.includes(targetId)) {
            // 非好友直接返回空数组（仍返回 history_response，避免前端因没响应而挂起加载）
            result.push({
                type: 'history_response',
                data: {messages: []}
            });
            return result;
        }
        messages = messageStore.getPrivateHistory(ctx.userId, targetId, count);
    }else{
        // 群聊：只要存在于 group.members 中就能拉（服务端 groupStore 找不到/非成员其实会拉到该群 JSON 的所有历史消息——此处补成员校验）
        const group = groupStore.findByGroupId(targetId);
        if (!group || !group.members.includes(ctx.userId)) {
            result.push({
                type: 'history_response',
                data: {messages: []}
            });
            return result;
        }
        messages = messageStore.getGroupHistory(targetId, count);
    }
    const formattedMessages = messages.map(m => {
        let senderName = m.senderUsername || '';
        let avatar = m.senderAvatar || '';
        // 兼容旧数据：旧消息可能字段名不同
        if(!senderName || !avatar){
            const user = userStore.findByUserId(m.sender);
            senderName = user?.username || m.sender;
            avatar = user?.avatar || '';
        }
        return {
            senderId: m.sender,
            senderUsername: senderName,
            senderAvatar: avatar,
            content: m.content,
            timestamp: m.timestamp,
            type: m.type,
        };
    });
    result.push({
        type: 'history_response',
        data: {messages: formattedMessages}
    });
    return result;
}
