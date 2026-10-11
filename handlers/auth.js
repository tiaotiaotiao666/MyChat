"use strict";
var __assign = (this && this.__assign) || function () {
    __assign = Object.assign || function(t) {
        for (var s, i = 1, n = arguments.length; i < n; i++) {
            s = arguments[i];
            for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p))
                t[p] = s[p];
        }
        return t;
    };
    return __assign.apply(this, arguments);
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.handleRegister = handleRegister;
exports.handleLogin = handleLogin;
var userStore = require("../store/users");
var groupStore = require("../store/groups");
var messageStore = require("../store/messages");
function handleRegister(msg, ctx) {
    var result = [];
    var username = msg.data.username;
    var password = msg.data.password;
    var avatar = msg.data.avatar;
    if (!username || !password || !avatar) {
        result.push({ type: 'register_response', data: { success: false, error: '缺少必填字段' } });
        return result;
    }
    if (username.length < 3 || username.length > 20) {
        result.push({ type: 'register_response', data: { success: false, error: '用户名长度应在3到20个字符之间' } });
        return result;
    }
    if (password.length < 6) {
        result.push({ type: 'register_response', data: { success: false, error: '密码长度应不少于6个字符' } });
        return result;
    }
    var existing = userStore.findByUsername(username);
    if (existing) {
        result.push({ type: 'register_response', data: { success: false, error: '用户名已存在' } });
        return result;
    }
    var user = userStore.createUser(username, password, avatar);
    ctx.userId = user.userId;
    var friends = userStore.getFriendsList(user);
    var friendRequests = user.friendRequests.filter(function (r) { return r.status === 'pending'; });
    var groups = groupStore.getGroupsForUser(user.userId);
    var friendsWithLastMsg = friends.map(function (f) {
        var lastMsg = messageStore.getPrivateLastMessage(user.userId, f.userId);
        return __assign(__assign({}, f), { lastMessage: lastMsg ? lastMsg.content : '', lastTime: lastMsg ? lastMsg.timestamp : '' });
    });
    var groupsWithLastMsg = groups.map(function (g) {
        var lastMsg = messageStore.getGroupLastMessage(g.groupId);
        return __assign(__assign({}, g), { lastMessage: lastMsg ? lastMsg.content : '', lastTime: lastMsg ? lastMsg.timestamp : '' });
    });
    var unreadCounts = userStore.getUnreadCounts(user.userId);
    var groupJoinRequests = groupStore.getPendingJoinRequestsForOwner(user.userId);
    result.push({
        type: 'register_response',
        data: {
            success: true,
            userId: user.userId,
            username: user.username,
            avatar: user.avatar,
            friends: friendsWithLastMsg,
            friendRequests: friendRequests,
            groups: groupsWithLastMsg,
            unreadCounts: unreadCounts,
            groupJoinRequests: groupJoinRequests
        }
    });
    return result;
}
function handleLogin(msg, ctx) {
    var result = [];
    var username = msg.data.username;
    var password = msg.data.password;
    if (!username || !password) {
        result.push({ type: 'login_response', data: { success: false, error: '缺少用户名或密码' } });
        return result;
    }
    var user = userStore.findByUsername(username);
    if (!user) {
        result.push({ type: 'login_response', data: { success: false, error: '用户不存在' } });
        return result;
    }
    if (!userStore.verifyPassword(user, password)) {
        result.push({ type: 'login_response', data: { success: false, error: '密码错误' } });
        return result;
    }
    ctx.userId = user.userId;
    var friends = userStore.getFriendsList(user);
    var friendRequests = user.friendRequests.filter(function (r) { return r.status === 'pending'; });
    var groups = groupStore.getGroupsForUser(user.userId);
    var friendsWithLastMsg = friends.map(function (f) {
        var lastMsg = messageStore.getPrivateLastMessage(user.userId, f.userId);
        return __assign(__assign({}, f), { lastMessage: lastMsg ? lastMsg.content : '', lastTime: lastMsg ? lastMsg.timestamp : '' });
    });
    var groupsWithLastMsg = groups.map(function (g) {
        var lastMsg = messageStore.getGroupLastMessage(g.groupId);
        return __assign(__assign({}, g), { lastMessage: lastMsg ? lastMsg.content : '', lastTime: lastMsg ? lastMsg.timestamp : '' });
    });
    var unreadCounts = userStore.getUnreadCounts(user.userId);
    var groupJoinRequests = groupStore.getPendingJoinRequestsForOwner(user.userId);
    result.push({ type: 'login_response', data: { success: true, userId: user.userId, username: user.username, avatar: user.avatar, friends: friendsWithLastMsg, friendRequests: friendRequests, groups: groupsWithLastMsg, unreadCounts: unreadCounts, groupJoinRequests: groupJoinRequests } });
    return result;
}
