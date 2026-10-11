"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.loadUsers = loadUsers;
exports.saveUsers = saveUsers;
exports.findByUsername = findByUsername;
exports.findByUserId = findByUserId;
exports.hashPassword = hashPassword;
exports.verifyPassword = verifyPassword;
exports.createUser = createUser;
exports.addFriend = addFriend;
exports.addFriendRequest = addFriendRequest;
exports.respondFriendRequest = respondFriendRequest;
exports.deleteFriend = deleteFriend;
exports.getFriendInfo = getFriendInfo;
exports.getFriendsList = getFriendsList;
exports.incrementUnread = incrementUnread;
exports.clearUnread = clearUnread;
exports.getUnreadCounts = getUnreadCounts;
var fs = require("fs");
var path = require("path");
var crypto = require("crypto");
var users = [];
var nextUserId = 1001;
var DATA_DIR = path.join(__dirname, '..', 'data');
var USERS_FILE = path.join(DATA_DIR, 'users.json');
function safeReadUsers() {
    if (!fs.existsSync(USERS_FILE))
        return [];
    var raw = fs.readFileSync(USERS_FILE, 'utf-8');
    if (raw.trim() === '')
        return [];
    return JSON.parse(raw);
}
function loadUsers() {
    if (!fs.existsSync(DATA_DIR)) {
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    var loaded = safeReadUsers();
    if (loaded.length > 0) {
        users = loaded;
        var maxId = 0;
        for (var _i = 0, users_1 = users; _i < users_1.length; _i++) {
            var u = users_1[_i];
            var num = parseInt(u.userId.replace('u_', ''));
            if (num > maxId) {
                maxId = num;
            }
        }
        nextUserId = maxId + 1;
    }
}
function saveUsers() {
    if (!fs.existsSync(DATA_DIR)) {
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), 'utf-8');
}
function findByUsername(username) {
    return users.find(function (u) { return u.username === username; });
}
function findByUserId(userId) {
    return users.find(function (u) { return u.userId === userId; });
}
function hashPassword(password) {
    var salt = crypto.randomBytes(16).toString('hex');
    var digest = crypto.createHash('sha256').update(salt + password).digest('hex');
    return "".concat(salt, ":").concat(digest);
}
function verifyPassword(user, password) {
    var stored = user.password || '';
    var idx = stored.indexOf(':');
    if (idx <= 0) {
        return crypto.createHash('sha256').update(password).digest('hex') === stored;
    }
    var salt = stored.slice(0, idx);
    var expectDigest = stored.slice(idx + 1);
    var actualDigest = crypto.createHash('sha256').update(salt + password).digest('hex');
    return actualDigest === expectDigest;
}
function createUser(username, password, avatar) {
    var user = {
        userId: 'u_' + nextUserId,
        username: username,
        password: hashPassword(password),
        avatar: avatar,
        friends: [],
        friendRequests: [],
        unreadCounts: {},
        createdAt: new Date().toISOString(),
    };
    users.push(user);
    nextUserId++;
    saveUsers();
    return user;
}
function addFriend(userId, friendId) {
    var user = findByUserId(userId);
    var friend = findByUserId(friendId);
    if (!user || !friend)
        return false;
    if (user.friends.includes(friendId))
        return false;
    user.friends.push(friendId);
    friend.friends.push(userId);
    saveUsers();
    return true;
}
function addFriendRequest(fromUser, toUser) {
    var exits = toUser.friendRequests.find(function (r) { return r.from === fromUser.userId && r.status === 'pending'; });
    if (exits)
        return false;
    toUser.friendRequests.push({
        from: fromUser.userId,
        username: fromUser.username,
        avatar: fromUser.avatar,
        status: 'pending'
    });
    saveUsers();
    return true;
}
function respondFriendRequest(toUser, fromUserId, agree) {
    var req = toUser.friendRequests.find(function (r) { return r.from === fromUserId && r.status === 'pending'; });
    if (!req)
        return false;
    req.status = agree ? 'accepted' : 'rejected';
    if (agree) {
        addFriend(toUser.userId, fromUserId);
        return true;
    }
    saveUsers();
    return true;
}
function deleteFriend(userId, friendId) {
    var user = findByUserId(userId);
    var friend = findByUserId(friendId);
    if (!user || !friend)
        return false;
    user.friends = user.friends.filter(function (f) { return f !== friendId; });
    friend.friends = friend.friends.filter(function (f) { return f !== userId; });
    saveUsers();
    return true;
}
function getFriendInfo(userId) {
    var user = findByUserId(userId);
    if (!user)
        return null;
    return {
        userId: user.userId,
        username: user.username,
        avatar: user.avatar
    };
}
function getFriendsList(user) {
    return user.friends
        .map(function (fid) { return getFriendInfo(fid); })
        .filter(function (f) { return f !== null; });
}
function incrementUnread(userId, targetId) {
    var user = findByUserId(userId);
    if (!user)
        return;
    if (!user.unreadCounts)
        user.unreadCounts = {};
    user.unreadCounts[targetId] = (user.unreadCounts[targetId] || 0) + 1;
    saveUsers();
}
function clearUnread(userId, targetId) {
    var user = findByUserId(userId);
    if (!user)
        return;
    if (!user.unreadCounts)
        user.unreadCounts = {};
    user.unreadCounts[targetId] = 0;
    saveUsers();
}
function getUnreadCounts(userId) {
    var user = findByUserId(userId);
    if (!user || !user.unreadCounts)
        return {};
    return user.unreadCounts;
}
