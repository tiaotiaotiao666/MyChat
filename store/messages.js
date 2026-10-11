"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.loadMessages = loadMessages;
exports.savePrivateMessage = savePrivateMessage;
exports.saveGroupMessage = saveGroupMessage;
exports.getPrivateHistory = getPrivateHistory;
exports.getGroupHistory = getGroupHistory;
exports.getPrivateLastMessage = getPrivateLastMessage;
exports.getGroupLastMessage = getGroupLastMessage;
var fs = require("fs");
var path = require("path");
var PRIVATE_DIR = path.join(__dirname, '..', 'data', 'messages', 'private');
var GROUPS_DIR = path.join(__dirname, '..', 'data', 'messages', 'groups');
var nextMessageId = 3001;
function safeReadMessages(filePath) {
    if (!fs.existsSync(filePath))
        return [];
    var raw = fs.readFileSync(filePath, 'utf-8');
    if (raw.trim() === '')
        return [];
    return JSON.parse(raw);
}
function loadMessages() {
    if (!fs.existsSync(PRIVATE_DIR))
        fs.mkdirSync(PRIVATE_DIR, { recursive: true });
    if (!fs.existsSync(GROUPS_DIR))
        fs.mkdirSync(GROUPS_DIR, { recursive: true });
    var maxId = 0;
    for (var _i = 0, _a = fs.readdirSync(PRIVATE_DIR); _i < _a.length; _i++) {
        var file = _a[_i];
        if (!file.endsWith('.json'))
            continue;
        var msgs = safeReadMessages(path.join(PRIVATE_DIR, file));
        for (var _b = 0, msgs_1 = msgs; _b < msgs_1.length; _b++) {
            var msg = msgs_1[_b];
            var num = parseInt(msg.messageId.replace('m_', ''));
            if (num > maxId) {
                maxId = num;
            }
        }
    }
    for (var _c = 0, _d = fs.readdirSync(GROUPS_DIR); _c < _d.length; _c++) {
        var file = _d[_c];
        if (!file.endsWith('.json'))
            continue;
        var msgs = safeReadMessages(path.join(GROUPS_DIR, file));
        for (var _e = 0, msgs_2 = msgs; _e < msgs_2.length; _e++) {
            var msg = msgs_2[_e];
            var num = parseInt(msg.messageId.replace('m_', ''));
            if (num > maxId) {
                maxId = num;
            }
        }
    }
    if (maxId > 0)
        nextMessageId = maxId + 1;
}
function getPrivateMessagesFileName(userId1, userId2) {
    var sortedIds = [userId1, userId2].sort();
    return path.join(PRIVATE_DIR, "".concat(sortedIds[0], "_").concat(sortedIds[1], ".json"));
}
function savePrivateMessage(sender, senderUsername, senderAvatar, target, content) {
    var msg = {
        messageId: "m_".concat(nextMessageId++),
        type: 'private_chat',
        sender: sender,
        senderUsername: senderUsername,
        senderAvatar: senderAvatar,
        target: target,
        groupId: null,
        content: content,
        timestamp: new Date().toISOString(),
    };
    var filePath = getPrivateMessagesFileName(sender, target);
    var messages = safeReadMessages(filePath);
    messages.push(msg);
    if (messages.length > 500) {
        var dropped = messages.length - 500;
        console.warn("[messages] private ".concat(sender, "<->").concat(target, ": \u4E22\u5F03\u6700\u65E9 ").concat(dropped, " \u6761\u6D88\u606F\uFF08\u8D85\u8FC7500\u6761\u4E0A\u9650\uFF09"));
        messages.splice(0, messages.length - 500);
    }
    fs.writeFileSync(filePath, JSON.stringify(messages, null, 2), 'utf-8');
    return msg;
}
function saveGroupMessage(sender, senderUsername, senderAvatar, groupId, content, target) {
    if (target === void 0) { target = null; }
    var msg = {
        messageId: "m_".concat(nextMessageId++),
        type: target ? 'group_private' : 'group_chat',
        sender: sender,
        senderUsername: senderUsername,
        senderAvatar: senderAvatar,
        target: target,
        groupId: groupId,
        content: content,
        timestamp: new Date().toISOString(),
    };
    var filePath = path.join(GROUPS_DIR, "".concat(groupId, ".json"));
    var messages = safeReadMessages(filePath);
    messages.push(msg);
    if (messages.length > 500) {
        var dropped = messages.length - 500;
        console.warn("[messages] group ".concat(groupId, ": \u4E22\u5F03\u6700\u65E9 ").concat(dropped, " \u6761\u6D88\u606F\uFF08\u8D85\u8FC7500\u6761\u4E0A\u9650\uFF09"));
        messages.splice(0, messages.length - 500);
    }
    fs.writeFileSync(filePath, JSON.stringify(messages, null, 2), 'utf-8');
    return msg;
}
function getPrivateHistory(userId1, userId2, count) {
    if (count === void 0) { count = 50; }
    var filePath = getPrivateMessagesFileName(userId1, userId2);
    var messages = safeReadMessages(filePath);
    return messages.slice(-count);
}
function getGroupHistory(groupId, count) {
    if (count === void 0) { count = 50; }
    var filePath = path.join(GROUPS_DIR, "".concat(groupId, ".json"));
    var messages = safeReadMessages(filePath);
    return messages.slice(-count);
}
function getPrivateLastMessage(userId1, userId2) {
    var filePath = getPrivateMessagesFileName(userId1, userId2);
    var messages = safeReadMessages(filePath);
    if (messages.length === 0)
        return null;
    return messages[messages.length - 1];
}
function getGroupLastMessage(groupId) {
    var filePath = path.join(GROUPS_DIR, "".concat(groupId, ".json"));
    var messages = safeReadMessages(filePath);
    if (messages.length === 0)
        return null;
    return messages[messages.length - 1];
}
