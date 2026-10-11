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
exports.loadGroups = loadGroups;
exports.saveGroups = saveGroups;
exports.findByGroupId = findByGroupId;
exports.searchByGroupName = searchByGroupName;
exports.existsByGroupName = existsByGroupName;
exports.createGroup = createGroup;
exports.isMember = isMember;
exports.addMember = addMember;
exports.addJoinRequest = addJoinRequest;
exports.respondJoinRequest = respondJoinRequest;
exports.removeMember = removeMember;
exports.dissolveGroup = dissolveGroup;
exports.getPendingJoinRequestsForOwner = getPendingJoinRequestsForOwner;
exports.getGroupsForUser = getGroupsForUser;
var fs = require("fs");
var path = require("path");
var users_1 = require("./users");
var groups = [];
var nextGroupId = 2001;
var DATA_DIR = path.join(__dirname, '..', 'data');
var GROUPS_FILE = path.join(DATA_DIR, 'groups.json');
function safeReadGroups() {
    if (!fs.existsSync(GROUPS_FILE))
        return [];
    var raw = fs.readFileSync(GROUPS_FILE, 'utf-8');
    if (raw.trim() === '')
        return [];
    return JSON.parse(raw);
}
function loadGroups() {
    if (!fs.existsSync(DATA_DIR)) {
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    var loaded = safeReadGroups();
    if (loaded.length > 0) {
        groups = loaded;
        var maxId = 0;
        for (var _i = 0, groups_1 = groups; _i < groups_1.length; _i++) {
            var g = groups_1[_i];
            var num = parseInt(g.groupId.replace('g_', ''));
            if (num > maxId) {
                maxId = num;
            }
        }
        nextGroupId = maxId + 1;
    }
}
function saveGroups() {
    if (!fs.existsSync(DATA_DIR)) {
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(GROUPS_FILE, JSON.stringify(groups, null, 2), 'utf-8');
}
function findByGroupId(groupId) {
    return groups.find(function (group) { return group.groupId === groupId; });
}
function searchByGroupName(groupName) {
    return groups.filter(function (group) { return group.groupName.includes(groupName); });
}
function existsByGroupName(groupName) {
    return groups.some(function (group) { return group.groupName === groupName; });
}
function createGroup(groupName, owner, memberIds) {
    var group = {
        groupId: 'g_' + nextGroupId,
        groupName: groupName,
        owner: owner,
        members: __spreadArray([], new Set(__spreadArray([owner], memberIds, true)), true),
        joinRequests: [],
        createdAt: new Date().toISOString(),
    };
    groups.push(group);
    nextGroupId++;
    saveGroups();
    return group;
}
function isMember(groupId, userId) {
    var group = findByGroupId(groupId);
    if (!group)
        return false;
    return group.members.includes(userId);
}
function addMember(groupId, userId) {
    var group = findByGroupId(groupId);
    if (!group)
        return false;
    // 修复BUG#3：用户已在群中应返回false，否则 handleGroupInvite 会误判"邀请成功"并重复发通知
    if (group.members.includes(userId)) {
        return false;
    }
    group.members.push(userId);
    saveGroups();
    return true;
}
function addJoinRequest(groupId, fromUserId, username, avatar) {
    var group = findByGroupId(groupId);
    if (!group)
        return false;
    var exists = group.joinRequests.find(function (r) { return r.from === fromUserId && r.status === 'pending'; });
    if (exists)
        return false;
    group.joinRequests.push({ from: fromUserId, username: username, avatar: avatar, status: 'pending' });
    saveGroups();
    return true;
}
function respondJoinRequest(groupId, fromUserId, agree) {
    var group = findByGroupId(groupId);
    if (!group)
        return false;
    var request = group.joinRequests.find(function (r) { return r.from === fromUserId && r.status === 'pending'; });
    if (!request)
        return false;
    request.status = agree ? 'accepted' : 'rejected';
    if (agree) {
        addMember(groupId, fromUserId);
        // addMember 内部已调用 saveGroups，跳过外层重复保存
        return true;
    }
    saveGroups();
    return true;
}
function removeMember(groupId, userId) {
    var group = findByGroupId(groupId);
    if (!group)
        return false;
    var index = group.members.indexOf(userId);
    if (index !== -1) {
        group.members.splice(index, 1);
        saveGroups();
        return true;
    }
    return false;
}
function dissolveGroup(groupId) {
    var index = groups.findIndex(function (group) { return group.groupId === groupId; });
    if (index !== -1) {
        groups.splice(index, 1);
        saveGroups();
        return true;
    }
    return false;
}
function getPendingJoinRequestsForOwner(userId) {
    var result = [];
    for (var _i = 0, groups_2 = groups; _i < groups_2.length; _i++) {
        var group = groups_2[_i];
        if (group.owner !== userId)
            continue;
        for (var _a = 0, _b = group.joinRequests; _a < _b.length; _a++) {
            var req = _b[_a];
            if (req.status === 'pending') {
                result.push({ groupId: group.groupId, groupName: group.groupName, from: req.from, username: req.username, avatar: req.avatar });
            }
        }
    }
    return result;
}
function getGroupsForUser(userId) {
    return groups
        .filter(function (group) { return group.members.includes(userId); })
        .map(function (group) {
        var _a;
        var ownerInfo = (0, users_1.getFriendInfo)(group.owner);
        return {
            groupId: group.groupId,
            groupName: group.groupName,
            owner: group.owner,
            ownerAvatar: (_a = ownerInfo === null || ownerInfo === void 0 ? void 0 : ownerInfo.avatar) !== null && _a !== void 0 ? _a : '',
            members: group.members,
        };
    });
}
