import { IncomingMessage, OutgoingMessage, ClientContext } from './types';
import * as userStore from '../store/users';
import * as groupStore from '../store/groups';
import * as messageStore from '../store/messages';

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

    const unreadCounts = userStore.getUnreadCounts(user.userId);
    const groupJoinRequests = groupStore.getPendingJoinRequestsForOwner(user.userId);

    result.push({
        type: 'register_response',
        data: {
            success: true,
            userId: user.userId,
            username: user.username,
            avatar: user.avatar,
            friends: friendsWithLastMsg,
            friendRequests,
            groups: groupsWithLastMsg,
            unreadCounts,
            groupJoinRequests
        }
    })
    return result;
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
    
    const unreadCounts = userStore.getUnreadCounts(user.userId);
    const groupJoinRequests = groupStore.getPendingJoinRequestsForOwner(user.userId);
    
    result.push({type: 'login_response', data: {success: true, userId: user.userId, username: user.username, avatar: user.avatar, friends: friendsWithLastMsg, friendRequests, groups: groupsWithLastMsg, unreadCounts, groupJoinRequests}});

    return result;
}
