"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.handleFriendSearch = handleFriendSearch;
exports.handleFriendRequest = handleFriendRequest;
exports.handleFriendRespond = handleFriendRespond;
exports.handleDeleteFriend = handleDeleteFriend;
var userStore = require("../store/users");
function handleFriendSearch(msg, ctx) {
    var result = [];
    if (!ctx.userId) {
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    var username = msg.data.username;
    var target = userStore.findByUsername(username);
    if (!target || target.userId === ctx.userId) {
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
function handleFriendRequest(msg, ctx, broadcastTo) {
    var result = [];
    if (!ctx.userId) {
        result.push({ type: 'error', data: { code: 401, message: '未登录' } });
        return result;
    }
    var fromUser = userStore.findByUserId(ctx.userId);
    var targetUserId = msg.data.targetUserId;
    var toUser = userStore.findByUserId(targetUserId);
    if (!fromUser || !toUser) {
        result.push({ type: 'error', data: { code: 404, message: '用户不存在' } });
        return result;
    }
    if (fromUser.friends.includes(toUser.userId)) {
        result.push({ type: 'friend_request_response', data: { success: false, error: '已经是好友' } });
        return result;
    }
    var ok = userStore.addFriendRequest(fromUser, toUser);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '已经发送过好友请求' } });
        return result;
    }
    result.push({ type: 'system', data: { text: "\u597D\u53CB\u8BF7\u6C42\u5DF2\u53D1\u9001\u7ED9 ".concat(toUser.username) } });
    broadcastTo(targetUserId, { type: 'friend_request', data: { fromUserId: fromUser.userId, fromUsername: fromUser.username, fromAvatar: fromUser.avatar } });
    return result;
}
function handleFriendRespond(msg, ctx, broadcastTo) {
    var result = [];
    if (!ctx.userId) {
        result.push({ type: 'error', data: { code: 401, message: '未登录' } });
        return result;
    }
    var fromUserId = msg.data.fromUserId;
    var agree = msg.data.agree;
    var toUser = userStore.findByUserId(ctx.userId);
    if (!toUser) {
        result.push({ type: 'error', data: { code: 404, message: '用户不存在' } });
        return result;
    }
    var ok = userStore.respondFriendRequest(toUser, fromUserId, agree);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '好友请求不存在或已处理' } });
        return result;
    }
    result.push({ type: 'system', data: { text: agree ? '已同意好友请求' : '已拒绝好友请求' } });
    var fromUser = userStore.findByUserId(fromUserId);
    broadcastTo(fromUserId, { type: 'friend_response', data: { fromUserId: ctx.userId, fromUsername: toUser.username, fromAvatar: toUser.avatar, agree: agree } });
    return result;
}
function handleDeleteFriend(msg, ctx, broadcastTo) {
    var _a, _b;
    var result = [];
    if (!ctx.userId) {
        result.push({ type: 'error', data: { code: 401, message: '未登录' } });
        return result;
    }
    var targetUserId = msg.data.targetUserId;
    var ok = userStore.deleteFriend(ctx.userId, targetUserId);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '删除好友失败' } });
        return result;
    }
    result.push({ type: 'system', data: { text: '好友已删除' } });
    var fromUser = userStore.findByUserId(ctx.userId);
    broadcastTo(targetUserId, {
        type: 'friend_deleted',
        data: {
            byUserId: ctx.userId,
            byUsername: (_a = fromUser === null || fromUser === void 0 ? void 0 : fromUser.username) !== null && _a !== void 0 ? _a : '',
            byAvatar: (_b = fromUser === null || fromUser === void 0 ? void 0 : fromUser.avatar) !== null && _b !== void 0 ? _b : ''
        }
    });
    return result;
}
