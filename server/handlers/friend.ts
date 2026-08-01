import { IncomingMessage, OutgoingMessage, ClientContext } from './types';
import * as userStore from '../store/users';

export function handleFriendSearch(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
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
    const username = msg.data.username as string;
    const target = userStore.findByUsername(username);
    if(!target || target.userId === ctx.userId){
        result.push({
            type: 'friend_search_response',
            data: {
                found: false
            }
        });
        return result;
    }
    result.push({
        type: 'friend_search_response',
        data: {
            found: true,
            userId: target.userId,
            username: target.username,
            avatar: target.avatar
        }
    });
    return result;
}
export function handleFriendRequest(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const targetUserId = msg.data.targetUserId as string;
    const toUser = userStore.findByUserId(targetUserId);
    if(!fromUser || !toUser){
        result.push({type: 'error', data: {code: 404, message: '用户不存在'}});
        return result;
    }

    if(fromUser.friends.includes(toUser.userId)){
        result.push({type: 'friend_request_response', data: {success: false, error: '已经是好友'}});
        return result;
    }

    const ok = userStore.addFriendRequest(fromUser, toUser);
    if(!ok){
        result.push({type: 'error', data: {code: 400, message: '已经发送过好友请求'}});
        return result;
    }
    result.push({type: 'system', data: { text: `好友请求已发送给 ${toUser.username}` }});
    broadcastTo(targetUserId, {type: 'friend_request', data: {fromUserId: fromUser.userId, fromUsername: fromUser.username, fromAvatar: fromUser.avatar}});
    return result;
}

export function handleFriendRespond(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const fromUserId = msg.data.fromUserId as string;
    const agree = msg.data.agree as boolean;
    const toUser = userStore.findByUserId(ctx.userId);
    if(!toUser){
        result.push({type: 'error', data: {code: 404, message: '用户不存在'}});
        return result;
    }
    const ok = userStore.respondFriendRequest(toUser, fromUserId, agree);
    if(!ok){
        result.push({type: 'error', data: {code: 400, message: '好友请求不存在或已处理'}});
        return result;
    }
    result.push({type: 'system', data: {text: agree ? '已同意好友请求' : '已拒绝好友请求'}});
    const fromUser = userStore.findByUserId(fromUserId);
    broadcastTo(fromUserId, {type: 'friend_response', data: {fromUserId: ctx.userId, fromUsername: toUser.username, fromAvatar: toUser.avatar, agree}});
    return result;
}

export function handleDeleteFriend(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId) {
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const targetUserId = msg.data.targetUserId as string;
    const ok = userStore.deleteFriend(ctx.userId, targetUserId);
    if(!ok) {
        result.push({type: 'error', data: {code: 400, message: '删除好友失败'}});
        return result;
    } 
    result.push({type: 'system', data: {text: '好友已删除'}});
    const fromUser = userStore.findByUserId(ctx.userId);
    broadcastTo(targetUserId, {
        type: 'friend_deleted',
        data: {
            byUserId: ctx.userId,
            byUsername: fromUser?.username ?? '',
            byAvatar: fromUser?.avatar ?? ''
        }
    });
    return result;
}
