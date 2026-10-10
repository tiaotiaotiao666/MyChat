const fs = require('fs');

// ========================== 改 1 ：group.ts respondJoinRequest 全员广播 group_member_joined
{
  const f = 'c:/Users/tiaotiao/Desktop/ChatRoom-Server/handlers/group.ts';
  let code = fs.readFileSync(f, 'utf8');
  const oldS = "    if(agree){\n        const joinedUser = userStore.findByUserId(fromUserId);\n        broadcastTo(ctx.userId, {type: 'group_member_joined', data: {groupId, groupName: group?.groupName || '', userId: fromUserId, username: joinedUser?.username || ''}});\n    }";
  if (!code.includes(oldS)) {
    console.log('FAIL 修改1 group.ts respondJoinRequest 旧串不匹配');
    process.exit(1);
  }
  const newS = "    if(agree){\n        const joinedUser = userStore.findByUserId(fromUserId);\n        // 🔴 BUG#1 修复：群主审批入群后，与 handleGroupInvite 保持一致——给所有群成员(排除新成员本人)逐个广播 group_member_joined\n        // 之前只 broadcastTo(ctx.userId)（群主本人收到）其他成员收不到，导致成员列表不实时刷新，必须重进群详情页\n        for (const memberId of group.members) {\n            if (memberId !== fromUserId) {\n                broadcastTo(memberId, {type: 'group_member_joined', data: {groupId, groupName: group.groupName, userId: fromUserId, username: joinedUser?.username || ''}});\n            }\n        }\n    }";
  code = code.replace(oldS, newS);
  fs.writeFileSync(f, code, 'utf8');
  console.log('OK 修改1 group.ts respondJoinRequest 全员广播 group_member_joined 完成');
}

// ========================== 改 2 ：message.ts handleHistoryRequest private 分支加好友校验
{
  const f2 = 'c:/Users/tiaotiao/Desktop/ChatRoom-Server/handlers/message.ts';
  let code2 = fs.readFileSync(f2, 'utf8');
  const old2 = "    const count = (msg.data.count as number) ?? 50;\n    let messages;\n    if(type === 'private'){\n        messages = messageStore.getPrivateHistory(ctx.userId, targetId, count);\n    }else{\n        messages = messageStore.getGroupHistory(targetId, count);\n    }";
  if (!code2.includes(old2)) {
    console.log('FAIL 修改2 message.ts handleHistoryRequest 旧串不匹配');
    process.exit(1);
  }
  const new2 = "    const count = (msg.data.count as number) ?? 50;\n    let messages;\n    if(type === 'private'){\n        // 🟢 BUG#3 修复：拉私聊历史前先验证双方是否仍为好友，防止删除好友后仍能通过 history_request 拉取聊天记录\n        const curUser = userStore.findByUserId(ctx.userId);\n        if (!curUser || !curUser.friends.includes(targetId)) {\n            // 非好友直接返回空数组（仍返回 history_response，避免前端因没响应而挂起加载）\n            result.push({\n                type: 'history_response',\n                data: {messages: []}\n            });\n            return result;\n        }\n        messages = messageStore.getPrivateHistory(ctx.userId, targetId, count);\n    }else{\n        // 群聊：只要存在于 group.members 中就能拉（服务端 groupStore 找不到/非成员其实会拉到该群 JSON 的所有历史消息——此处补成员校验）\n        const group = groupStore.findByGroupId(targetId);\n        if (!group || !group.members.includes(ctx.userId)) {\n            result.push({\n                type: 'history_response',\n                data: {messages: []}\n            });\n            return result;\n        }\n        messages = messageStore.getGroupHistory(targetId, count);\n    }";
  code2 = code2.replace(old2, new2);
  fs.writeFileSync(f2, code2, 'utf8');
  console.log('OK 修改2 message.ts handleHistoryRequest 好友校验+群成员校验完成');
}
