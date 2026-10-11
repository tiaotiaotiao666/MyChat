import { IncomingMessage, OutgoingMessage, ClientContext } from './types';
import * as userStore from '../store/users';
import * as groupStore from '../store/groups';
import * as messageStore from '../store/messages';
import * as tokenStore from '../store/tokens';

// 登录/注册/token登录共用的"成功大礼包"：完整好友/群/未读状态一把梭返回
// issueToken：密码登录/注册=true（签发新通行证）；token续登=false（旧证继续用，
//   否则每次重连换新证，5张上限一挤就把客户端手里那张挤失效了，纯属自己坑自己）
function buildAuthSuccess(type: string, user: userStore.User, issueToken: boolean): OutgoingMessage[] {
    const friends = userStore.getFriendsList(user);
    const friendRequests = user.friendRequests.filter(r => r.status === 'pending');
    const groups = groupStore.getGroupsForUser(user.userId);

    const friendsWithLastMsg = friends.map(f => {
        const lastMsg = messageStore.getPrivateLastMessage(user.userId, f.userId);
        return {
            ...f,
            lastMessage: lastMsg ? lastMsg.content : '',
            lastTime: lastMsg ? lastMsg.timestamp : ''
        };
    });

    const groupsWithLastMsg = groups.map(g => {
        const lastMsg = messageStore.getGroupLastMessage(g.groupId);
        return {
            ...g,
            lastMessage: lastMsg ? lastMsg.content : '',
            lastTime: lastMsg ? lastMsg.timestamp : ''
        };
    });

    const data: Record<string, unknown> = {
        success: true,
        userId: user.userId,
        username: user.username,
        avatar: user.avatar,
        friends: friendsWithLastMsg,
        friendRequests,
        groups: groupsWithLastMsg,
        unreadCounts: userStore.getUnreadCounts(user.userId),
        groupJoinRequests: groupStore.getPendingJoinRequestsForOwner(user.userId)
    };
    if (issueToken) {
        // 安全加固#8：顺手发一张"通行证"——客户端保存它，之后重连/重启免密续登
        data.token = tokenStore.issueToken(user.userId, user.username);
    }
    return [{ type, data }];
}

export function handleRegister(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    const username = msg.data.username as string;
    const password = msg.data.password as string;
    const avatar = msg.data.avatar as string;
    if(!username || !password || !avatar){
        result.push({type: 'register_response', data: {success: false, error: '缺少必填字段'}});
        return result;
    }
    if(username.length < 3 || username.length > 20){
        result.push({type: 'register_response', data: {success: false, error: '用户名长度应在3到20个字符之间'}});
        return result;
    }
    if(password.length < 6 ){
        result.push({type: 'register_response', data: {success: false, error: '密码长度应不少于6个字符'}});
        return result;
    }
    const existing = userStore.findByUsername(username);
    if(existing){
        result.push({type: 'register_response', data: {success: false, error: '用户名已存在'}});
        return result;
    }
    const user = userStore.createUser(username, password, avatar);
    ctx.userId = user.userId;
    return buildAuthSuccess('register_response', user, true);
}

export function handleLogin(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    const username = msg.data.username as string;
    const password = msg.data.password as string;
    if(!username || !password){
        result.push({type: 'login_response', data: {success: false, error: '缺少用户名或密码'}});
        return result;
    }
    const user = userStore.findByUsername(username);
    if(!user){
        result.push({type: 'login_response', data: {success: false, error: '用户不存在'}});
        return result;
    }
    if(!userStore.verifyPassword(user, password)){
        result.push({type: 'login_response', data: {success: false, error: '密码错误'}});
        return result;
    }
    ctx.userId = user.userId;
    return buildAuthSuccess('login_response', user, true);
}

// 安全加固#8：凭token免密登录——客户端重连/重启时用它，密码从此不用反复出门
export function handleLoginToken(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    const username = msg.data.username as string;
    const token = msg.data.token as string;
    if(!username || !token){
        result.push({type: 'login_response', data: {success: false, error: '缺少用户名或token'}});
        return result;
    }
    const entry = tokenStore.validateToken(token);
    // 失败话术统一——不区分"token不存在/被吊销/对不上号"，不给试探者任何额外线索
    const failMsg = '登录已失效，请重新输入密码';
    if(!entry || entry.username !== username){
        result.push({type: 'login_response', data: {success: false, error: failMsg}});
        return result;
    }
    const user = userStore.findByUsername(username);
    if(!user || user.userId !== entry.userId){
        result.push({type: 'login_response', data: {success: false, error: failMsg}});
        return result;
    }
    ctx.userId = user.userId;
    return buildAuthSuccess('login_response', user, false);
}
