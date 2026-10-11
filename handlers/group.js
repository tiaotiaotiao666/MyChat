"use strict";
var __spreadArray = (this && this.__spreadArray) || function (to, from, pack) {
    if (pack || arguments.length === 2) for (var i = 0, l = from.length, ar; i < l; i++) {
        if (ar || !(i in from)) {
            if (!ar) ar = Array.prototype.slice.call(from, 0, i);
            ar[i] = from[i];
        }
    }
    return to.concat(ar || Array.prototype.slice.call(from));
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.handleCreateGroup = handleCreateGroup;
exports.handleGroupSearch = handleGroupSearch;
exports.handleGroupJoinRequest = handleGroupJoinRequest;
exports.handleGroupJoinRespond = handleGroupJoinRespond;
exports.handleGroupInvite = handleGroupInvite;
exports.handleGroupLeave = handleGroupLeave;
exports.handleGroupDissolve = handleGroupDissolve;
exports.handleGroupMembers = handleGroupMembers;
exports.handleGroupKick = handleGroupKick;
var userStore = require("../store/users");
var groupStore = require("../store/groups");
function handleCreateGroup(msg, ctx, broadcastTo) {
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
    var groupName = msg.data.groupName;
    var memberIds = msg.data.memberIds;
    if (!groupName) {
        result.push({ type: 'error', data: { code: 400, message: '群组名称不能为空' } });
        return result;
    }
    if (groupStore.existsByGroupName(groupName)) {
        result.push({ type: 'error', data: { code: 400, message: '群名已存在，请换一个' } });
        return result;
    }
    var fromUser = userStore.findByUserId(ctx.userId);
    if (!fromUser) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户不存在'
            }
        });
        return result;
    }
    var group = groupStore.createGroup(groupName, ctx.userId, memberIds || []);
    result.push({
        type: 'create_group_response',
        data: {
            success: true,
            groupId: group.groupId,
            groupName: group.groupName,
            ownerAvatar: fromUser.avatar,
            owner: group.owner,
            members: group.members
        }
    });
    for (var _i = 0, _a = group.members; _i < _a.length; _i++) {
        var memberId = _a[_i];
        if (memberId !== ctx.userId) {
            broadcastTo(memberId, {
                type: 'group_invite',
                data: {
                    groupId: group.groupId,
                    groupName: group.groupName,
                    inviterUsername: fromUser.username,
                    ownerAvatar: fromUser.avatar,
                    owner: group.owner,
                    members: group.members
                }
            });
        }
    }
    return result;
}
function handleGroupSearch(msg, ctx) {
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
    var groupName = msg.data.groupName;
    // BUG#7：群搜索空字符串 / 非字符串 直接返回空 groups，防止泄露全部群列表
    if (typeof groupName !== 'string' || groupName.trim() === '') {
        result.push({
            type: 'group_search_response',
            data: { groups: [] }
        });
        return result;
    }
    var groups = groupStore.searchByGroupName(groupName);
    result.push({
        type: 'group_search_response',
        data: {
            groups: groups.map(function (g) {
                var _a;
                var ownerInfo = userStore.getFriendInfo(g.owner);
                return {
                    groupId: g.groupId,
                    groupName: g.groupName,
                    owner: g.owner,
                    ownerAvatar: (_a = ownerInfo === null || ownerInfo === void 0 ? void 0 : ownerInfo.avatar) !== null && _a !== void 0 ? _a : '',
                    members: g.members.length
                };
            })
        }
    });
    return result;
}
function handleGroupJoinRequest(msg, ctx, broadcastTo) {
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
    var groupId = msg.data.groupId;
    var fromUser = userStore.findByUserId(ctx.userId);
    var group = groupStore.findByGroupId(groupId);
    if (!fromUser || !group) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户或群组不存在'
            }
        });
        return result;
    }
    if (group.members.includes(ctx.userId)) {
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '已经是群成员'
            }
        });
        return result;
    }
    var ok = groupStore.addJoinRequest(groupId, ctx.userId, fromUser.username, fromUser.avatar);
    if (!ok) {
        result.push({ type: 'error', data: { code: 500, message: '已发送过入群申请' } });
        return result;
    }
    result.push({ type: 'system', data: { groupId: groupId, groupName: group.groupName, text: "\u5165\u7FA4\u7533\u8BF7\u5DF2\u53D1\u9001\u7ED9\u7FA4\u4E3B ".concat(group.owner) } });
    broadcastTo(group.owner, { type: 'group_join_request', data: { groupId: groupId, groupName: group.groupName, fromUserId: ctx.userId, fromUsername: fromUser.username, fromAvatar: fromUser.avatar } });
    return result;
}
function handleGroupJoinRespond(msg, ctx, broadcastTo) {
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
    var fromUserId = msg.data.fromUserId;
    var agree = msg.data.agree;
    var groupId = msg.data.groupId;
    var group = groupStore.findByGroupId(groupId);
    if (!group) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if (group.owner !== ctx.userId) {
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '没有权限处理入群申请'
            }
        });
        return result;
    }
    var ok = groupStore.respondJoinRequest(groupId, fromUserId, agree);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '没有待处理的入群申请' } });
        return result;
    }
    result.push({ type: 'system', data: { groupId: groupId, groupName: group.groupName, text: "".concat(agree ? '已同意' : '已拒绝', " \u5165\u7FA4\u7533\u8BF7") } });
    var ownerInfo = userStore.getFriendInfo(ctx.userId);
    broadcastTo(fromUserId, { type: 'group_join_response', data: { groupId: groupId, groupName: (group === null || group === void 0 ? void 0 : group.groupName) || '', ownerAvatar: (ownerInfo === null || ownerInfo === void 0 ? void 0 : ownerInfo.avatar) || '', owner: (group === null || group === void 0 ? void 0 : group.owner) || '', members: (group === null || group === void 0 ? void 0 : group.members) || [], agree: agree } });
    if (agree) {
        var joinedUser = userStore.findByUserId(fromUserId);
        // 🔴 BUG#1 修复：群主审批入群后，与 handleGroupInvite 保持一致——给所有群成员(排除新成员本人)逐个广播 group_member_joined
        // 之前只 broadcastTo(ctx.userId)（群主本人收到）其他成员收不到，导致成员列表不实时刷新，必须重进群详情页
        for (var _i = 0, _a = group.members; _i < _a.length; _i++) {
            var memberId = _a[_i];
            if (memberId !== fromUserId) {
                broadcastTo(memberId, { type: 'group_member_joined', data: { groupId: groupId, groupName: group.groupName, userId: fromUserId, username: (joinedUser === null || joinedUser === void 0 ? void 0 : joinedUser.username) || '' } });
            }
        }
    }
    return result;
}
function handleGroupInvite(msg, ctx, broadcastTo) {
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
    var groupId = msg.data.groupId;
    var targetUserId = msg.data.targetUserId;
    var fromUser = userStore.findByUserId(ctx.userId);
    var group = groupStore.findByGroupId(groupId);
    var targetUser = userStore.findByUserId(targetUserId);
    if (!fromUser || !group || !targetUser) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户或群组不存在'
            }
        });
        return result;
    }
    if (!group.members.includes(ctx.userId)) {
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '不是群组成员'
            }
        });
        return result;
    }
    var ok = groupStore.addMember(groupId, targetUserId);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '邀请失败，对方已经是群组成员' } });
        return result;
    }
    result.push({ type: 'system', data: { groupId: groupId, groupName: group.groupName, text: '已邀请入群' } });
    var ownerInfo = userStore.getFriendInfo(group.owner);
    broadcastTo(targetUserId, { type: 'group_invite', data: { groupId: groupId, groupName: group.groupName, inviterUsername: fromUser.username, ownerAvatar: (ownerInfo === null || ownerInfo === void 0 ? void 0 : ownerInfo.avatar) || '', owner: group.owner, members: group.members } });
    // 邀请成功后，给所有群成员(除被邀请者自己)也推 group_member_joined，与同意入群申请逻辑一致，成员列表及时刷新
    var targetUserInfo = userStore.findByUserId(targetUserId);
    for (var _i = 0, _a = group.members; _i < _a.length; _i++) {
        var memberId = _a[_i];
        if (memberId !== targetUserId) {
            broadcastTo(memberId, { type: 'group_member_joined', data: { groupId: groupId, groupName: group.groupName, userId: targetUserId, username: (targetUserInfo === null || targetUserInfo === void 0 ? void 0 : targetUserInfo.username) || '' } });
        }
    }
    return result;
}
function handleGroupLeave(msg, ctx, broadcastTo) {
    var _a;
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
    var groupId = msg.data.groupId;
    var group = groupStore.findByGroupId(groupId);
    if (!group) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if (group.owner === ctx.userId) {
        result.push({ type: 'error', data: { code: 400, message: '群主不能退群， 请解散群' } });
        return result;
    }
    var fromUser = userStore.findByUserId(ctx.userId);
    var membersBeforeLeave = __spreadArray([], group.members, true);
    var ok = groupStore.removeMember(groupId, ctx.userId);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '退群失败' } });
        return result;
    }
    result.push({ type: 'system', data: { text: "\u5DF2\u9000\u7FA4" } });
    for (var _i = 0, membersBeforeLeave_1 = membersBeforeLeave; _i < membersBeforeLeave_1.length; _i++) {
        var memberId = membersBeforeLeave_1[_i];
        if (memberId !== ctx.userId) {
            broadcastTo(memberId, { type: 'group_leave', data: { groupId: groupId, userId: ctx.userId, username: (_a = fromUser === null || fromUser === void 0 ? void 0 : fromUser.username) !== null && _a !== void 0 ? _a : '' } });
        }
    }
    broadcastTo(ctx.userId, { type: 'group_self_left', data: { groupId: groupId } });
    return result;
}
function handleGroupDissolve(msg, ctx, broadcastTo) {
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
    var groupId = msg.data.groupId;
    var group = groupStore.findByGroupId(groupId);
    if (!group) {
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if (group.owner !== ctx.userId) {
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '没有权限解散群组'
            }
        });
        return result;
    }
    var members = __spreadArray([], group.members, true);
    var groupName = group.groupName;
    var ok = groupStore.dissolveGroup(groupId);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '解散群组失败' } });
        return result;
    }
    result.push({ type: 'system', data: { text: "\u5DF2\u89E3\u6563\u7FA4\u7EC4" } });
    for (var _i = 0, members_1 = members; _i < members_1.length; _i++) {
        var memberId = members_1[_i];
        broadcastTo(memberId, { type: 'group_dissolved', data: { groupId: groupId, groupName: groupName } });
    }
    return result;
}
function handleGroupMembers(msg, ctx) {
    var result = [];
    if (!ctx.userId) {
        result.push({ type: 'error', data: { code: 401, message: '未登录' } });
        return result;
    }
    var groupId = msg.data.groupId;
    var group = groupStore.findByGroupId(groupId);
    if (!group) {
        result.push({ type: 'error', data: { code: 404, message: '群组不存在' } });
        return result;
    }
    if (!group.members.includes(ctx.userId)) {
        result.push({ type: 'error', data: { code: 403, message: '不是群组成员' } });
        return result;
    }
    var members = group.members.map(function (memberId) {
        var _a, _b;
        var info = userStore.getFriendInfo(memberId);
        return {
            userId: memberId,
            username: (_a = info === null || info === void 0 ? void 0 : info.username) !== null && _a !== void 0 ? _a : '',
            avatar: (_b = info === null || info === void 0 ? void 0 : info.avatar) !== null && _b !== void 0 ? _b : '',
            isOwner: memberId === group.owner
        };
    });
    result.push({ type: 'group_members_response', data: { groupId: groupId, members: members } });
    return result;
}
function handleGroupKick(msg, ctx, broadcastTo) {
    var _a, _b;
    var result = [];
    if (!ctx.userId) {
        result.push({ type: 'error', data: { code: 401, message: '未登录' } });
        return result;
    }
    var groupId = msg.data.groupId;
    var targetUserId = msg.data.targetUserId;
    var group = groupStore.findByGroupId(groupId);
    if (!group) {
        result.push({ type: 'error', data: { code: 404, message: '群组不存在' } });
        return result;
    }
    if (group.owner !== ctx.userId) {
        result.push({ type: 'error', data: { code: 403, message: '只有群主才能踢人' } });
        return result;
    }
    if (targetUserId === ctx.userId) {
        result.push({ type: 'error', data: { code: 400, message: '不能踢自己，请解散群组' } });
        return result;
    }
    var membersBeforeKick = __spreadArray([], group.members, true);
    var ok = groupStore.removeMember(groupId, targetUserId);
    if (!ok) {
        result.push({ type: 'error', data: { code: 400, message: '踢人失败，该用户不是群成员' } });
        return result;
    }
    var targetUser = userStore.findByUserId(targetUserId);
    result.push({ type: 'system', data: { text: "\u5DF2\u5C06 ".concat((_a = targetUser === null || targetUser === void 0 ? void 0 : targetUser.username) !== null && _a !== void 0 ? _a : targetUserId, " \u79FB\u51FA\u7FA4\u7EC4") } });
    // 通知所有群成员（包括群主自己），除被踢者外
    for (var _i = 0, membersBeforeKick_1 = membersBeforeKick; _i < membersBeforeKick_1.length; _i++) {
        var memberId = membersBeforeKick_1[_i];
        if (memberId !== targetUserId) {
            broadcastTo(memberId, { type: 'group_kick', data: { groupId: groupId, targetUserId: targetUserId, targetUsername: (_b = targetUser === null || targetUser === void 0 ? void 0 : targetUser.username) !== null && _b !== void 0 ? _b : '' } });
        }
    }
    broadcastTo(targetUserId, { type: 'group_self_kicked', data: { groupId: groupId, groupName: group.groupName } });
    return result;
}
