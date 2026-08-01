const fs = require('fs');
{
  const f = 'c:/Users/tiaotiao/Desktop/ChatRoom-Server/handlers/group.ts';
  let code = fs.readFileSync(f, 'utf8');
  let fails = [];

  // 修改A：create_group_response 加 members 字段（Marvis建议4修复）
  const oldA = "    const group = groupStore.createGroup(groupName, ctx.userId, memberIds || []);\n    result.push({\n        type: 'create_group_response',\n        data: {\n            success: true,\n            groupId: group.groupId,\n            groupName: group.groupName,\n            ownerAvatar: fromUser.avatar\n        }\n    });";
  const newA = "    const group = groupStore.createGroup(groupName, ctx.userId, memberIds || []);\n    result.push({\n        type: 'create_group_response',\n        data: {\n            success: true,\n            groupId: group.groupId,\n            groupName: group.groupName,\n            ownerAvatar: fromUser.avatar,\n            owner: group.owner,\n            members: group.members\n        }\n    });";
  if (!code.includes(oldA)) fails.push('A create_group_response加members'); else code = code.replace(oldA, newA);

  // 修改B：handleCreateGroup 的 group_invite 广播也补 members（Marvis建议4修复，chatListPage.addGroupToAppStorage要用到）
  const oldB = "            broadcastTo(memberId, {\n                type: 'group_invite',\n                data: {\n                    groupId: group.groupId,\n                    groupName: group.groupName,\n                    inviterUsername: fromUser.username,\n                    ownerAvatar: fromUser.avatar,\n                }\n            });";
  const newB = "            broadcastTo(memberId, {\n                type: 'group_invite',\n                data: {\n                    groupId: group.groupId,\n                    groupName: group.groupName,\n                    inviterUsername: fromUser.username,\n                    ownerAvatar: fromUser.avatar,\n                    owner: group.owner,\n                    members: group.members\n                }\n            });";
  if (!code.includes(oldB)) fails.push('B handleCreateGroup的group_invite加members'); else code = code.replace(oldB, newB);

  // 修改C：handleGroupJoinRespond 给 fromUserId 的 group_join_response 加 members（Marvis建议4修复）
  const oldC = "    broadcastTo(fromUserId, {type: 'group_join_response', data: {groupId, groupName: group?.groupName || '', ownerAvatar: ownerInfo?.avatar || '', agree}});";
  const newC = "    broadcastTo(fromUserId, {type: 'group_join_response', data: {groupId, groupName: group?.groupName || '', ownerAvatar: ownerInfo?.avatar || '', owner: group?.owner || '', members: group?.members || [], agree}});";
  if (!code.includes(oldC)) fails.push('C join_respond的group_join_response加members'); else code = code.replace(oldC, newC);

  // 修改D：handleGroupInvite 给 targetUserId 的 group_invite 广播 加 members 字段（之前没加，Marvis建议4修复）
  const oldD = "    broadcastTo(targetUserId, {type: 'group_invite', data: {groupId, groupName: group.groupName, inviterUsername: fromUser.username, ownerAvatar: ownerInfo?.avatar || ''}});";
  const newD = "    broadcastTo(targetUserId, {type: 'group_invite', data: {groupId, groupName: group.groupName, inviterUsername: fromUser.username, ownerAvatar: ownerInfo?.avatar || '', owner: group.owner, members: group.members}});";
  if (!code.includes(oldD)) fails.push('D handleGroupInvite的group_invite加members'); else code = code.replace(oldD, newD);

  if (fails.length > 0) { console.log('FAIL：', fails); process.exit(1); }
  fs.writeFileSync(f, code, 'utf8');
  console.log('OK group.ts A/B/C/D 四处消息补members/owner字段 完成');
}
