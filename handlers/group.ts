import { IncomingMessage, OutgoingMessage, ClientContext } from './types';
import * as userStore from '../store/users';
import * as groupStore from '../store/groups'

export function handleCreateGroup(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const groupName = msg.data.groupName as string;
    const memberIds = msg.data.memberIds as string[];
    if(!groupName){
        result.push({type: 'error', data: {code: 400, message: '群组名称不能为空'}});
        return result;
    }
    if(groupStore.existsByGroupName(groupName)){
        result.push({type: 'error', data: {code: 400, message: '群名已存在，请换一个'}});
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    if(!fromUser){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户不存在'
            }
        });
        return result;
    }
    const group = groupStore.createGroup(groupName, ctx.userId, memberIds || []);
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
    for(const memberId of group.members){
        if(memberId !== ctx.userId){
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

export function handleGroupSearch(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const groupName = msg.data.groupName as string;
    // BUG#7：群搜索空字符串 / 非字符串 直接返回空 groups，防止泄露全部群列表
    if (typeof groupName !== 'string' || groupName.trim() === '') {
        result.push({
            type: 'group_search_response',
            data: { groups: [] }
        });
        return result;
    }
    const groups = groupStore.searchByGroupName(groupName);
    result.push({
        type: 'group_search_response',
        data: {
            groups: groups.map(g => {
                const ownerInfo = userStore.getFriendInfo(g.owner);
                return {
                    groupId: g.groupId,
                    groupName: g.groupName,
                    owner: g.owner,
                    ownerAvatar: ownerInfo?.avatar ?? '',
                    members: g.members.length
                };
            })
        }
    });
    return result;
}
export function handleGroupJoinRequest(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){ 
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const groupId = msg.data.groupId as string;
    const fromUser = userStore.findByUserId(ctx.userId);
    const group = groupStore.findByGroupId(groupId);
    if(!fromUser || !group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户或群组不存在'
            }
        });
        return result;
    }  
    if(group.members.includes(ctx.userId)){
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '已经是群成员'
            }
        });
        return result;
    }
    const ok = groupStore.addJoinRequest(groupId, ctx.userId, fromUser.username, fromUser.avatar);
    if(!ok){
        result.push({type: 'error', data:{code: 500, message: '已发送过入群申请'}});
        return result;
    }
    result.push({type: 'system', data:{groupId, groupName: group.groupName, text: `入群申请已发送给群主 ${group.owner}`}});
    broadcastTo(group.owner, {type: 'group_join_request', data: {groupId, groupName: group.groupName, fromUserId: ctx.userId, fromUsername: fromUser.username, fromAvatar: fromUser.avatar}});
    return result;
}
export function handleGroupJoinRespond(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){ 
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const fromUserId = msg.data.fromUserId as string;
    const agree = msg.data.agree as boolean;
    const groupId = msg.data.groupId as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if(group.owner !== ctx.userId){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '没有权限处理入群申请'
            }
        });
        return result;
    }
    const ok = groupStore.respondJoinRequest(groupId, fromUserId, agree);
    if(!ok){
        result.push({type: 'error', data:{code: 400, message: '没有待处理的入群申请'}});
        return result;
    }
    result.push({type: 'system', data:{groupId, groupName: group.groupName, text: `${agree ? '已同意' : '已拒绝'} 入群申请`}});
    const ownerInfo = userStore.getFriendInfo(ctx.userId);
    broadcastTo(fromUserId, {type: 'group_join_response', data: {groupId, groupName: group?.groupName || '', ownerAvatar: ownerInfo?.avatar || '', owner: group?.owner || '', members: group?.members || [], agree}});
    if(agree){
        const joinedUser = userStore.findByUserId(fromUserId);
        // 🔴 BUG#1 修复：群主审批入群后，与 handleGroupInvite 保持一致——给所有群成员(排除新成员本人)逐个广播 group_member_joined
        // 之前只 broadcastTo(ctx.userId)（群主本人收到）其他成员收不到，导致成员列表不实时刷新，必须重进群详情页
        for (const memberId of group.members) {
            if (memberId !== fromUserId) {
                broadcastTo(memberId, {type: 'group_member_joined', data: {groupId, groupName: group.groupName, userId: fromUserId, username: joinedUser?.username || ''}});
            }
        }
    }
    return result;
}
export function handleGroupInvite(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
        if(!ctx.userId){ 
           result.push({
              type: 'error',
              data: {
                  code: 401,
                  message: '未登录'
              }
          });
           return result;
     }
    const groupId = msg.data.groupId as string;
    const targetUserId = msg.data.targetUserId as string;
    const fromUser = userStore.findByUserId(ctx.userId);
    const group = groupStore.findByGroupId(groupId);
    const targetUser = userStore.findByUserId(targetUserId);
    if(!fromUser || !group || !targetUser){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '用户或群组不存在'
            }
        });
        return result;
    }
    if(!group.members.includes(ctx.userId)){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '不是群组成员'
            }
        });
        return result;
    }
    const ok = groupStore.addMember(groupId, targetUserId);
    if(!ok){
        result.push({type: 'error', data:{code: 400, message: '邀请失败，对方已经是群组成员'}}  );
        return result;
    }
    result.push({type: 'system', data: {groupId, groupName: group.groupName, text: '已邀请入群'}})
    const ownerInfo = userStore.getFriendInfo(group.owner);
    broadcastTo(targetUserId, {type: 'group_invite', data: {groupId, groupName: group.groupName, inviterUsername: fromUser.username, ownerAvatar: ownerInfo?.avatar || '', owner: group.owner, members: group.members}});
    // 邀请成功后，给所有群成员(除被邀请者自己)也推 group_member_joined，与同意入群申请逻辑一致，成员列表及时刷新
    const targetUserInfo = userStore.findByUserId(targetUserId);
    for (const memberId of group.members) {
        if (memberId !== targetUserId) {
            broadcastTo(memberId, {type: 'group_member_joined', data: {groupId, groupName: group.groupName, userId: targetUserId, username: targetUserInfo?.username || ''}});
        }
    }
    return result;
}
export function handleGroupLeave(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){ 
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const groupId = msg.data.groupId as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if(group.owner === ctx.userId){
        result.push({type: 'error', data:{code: 400, message: '群主不能退群， 请解散群'}});
        return result;
    }
    const fromUser = userStore.findByUserId(ctx.userId);
    const membersBeforeLeave = [...group.members];
    const ok = groupStore.removeMember(groupId, ctx.userId);
    if(!ok){
        result.push({type: 'error', data:{code: 400, message: '退群失败'}});
        return result;
    }
    result.push({type: 'system', data: {text: `已退群`}});
    for(const memberId of membersBeforeLeave){
        if(memberId !== ctx.userId){
            broadcastTo(memberId, {type: 'group_leave', data: {groupId, userId: ctx.userId, username: fromUser?.username ?? ''}});
        }
    }
    broadcastTo(ctx.userId, {type: 'group_self_left', data: {groupId}});
    return result;
}
export function handleGroupDissolve(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){ 
        result.push({
            type: 'error',
            data: {
                code: 401,
                message: '未登录'
            }
        });
        return result;
    }
    const groupId = msg.data.groupId as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({
            type: 'error',
            data: {
                code: 404,
                message: '群组不存在'
            }
        });
        return result;
    }
    if(group.owner !== ctx.userId){
        result.push({
            type: 'error',
            data: {
                code: 403,
                message: '没有权限解散群组'
            }
        });
        return result;
    }
    const members = [...group.members]
    const groupName = group.groupName;
    const ok = groupStore.dissolveGroup(groupId);
    if(!ok){
        result.push({type: 'error', data:{code: 400, message: '解散群组失败'}});
        return result;
    }
    result.push({type: 'system', data: {text: `已解散群组`}});
    for(const memberId of members){
        broadcastTo(memberId, {type: 'group_dissolved', data: {groupId, groupName}});
    }
    return result;
}

export function handleGroupMembers(msg: IncomingMessage, ctx: ClientContext): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const groupId = msg.data.groupId as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({type: 'error', data: {code: 404, message: '群组不存在'}});
        return result;
    }
    if(!group.members.includes(ctx.userId)){
        result.push({type: 'error', data: {code: 403, message: '不是群组成员'}});
        return result;
    }
    const members = group.members.map(memberId => {
        const info = userStore.getFriendInfo(memberId);
        return {
            userId: memberId,
            username: info?.username ?? '',
            avatar: info?.avatar ?? '',
            isOwner: memberId === group.owner
        };
    });
    result.push({type: 'group_members_response', data: {groupId, members}});
    return result;
}

export function handleGroupKick(msg: IncomingMessage, ctx: ClientContext, broadcastTo: (userId: string, msg: OutgoingMessage) => void): OutgoingMessage[] {
    const result: OutgoingMessage[] = [];
    if(!ctx.userId){
        result.push({type: 'error', data: {code: 401, message: '未登录'}});
        return result;
    }
    const groupId = msg.data.groupId as string;
    const targetUserId = msg.data.targetUserId as string;
    const group = groupStore.findByGroupId(groupId);
    if(!group){
        result.push({type: 'error', data: {code: 404, message: '群组不存在'}});
        return result;
    }
    if(group.owner !== ctx.userId){
        result.push({type: 'error', data: {code: 403, message: '只有群主才能踢人'}});
        return result;
    }
    if(targetUserId === ctx.userId){
        result.push({type: 'error', data: {code: 400, message: '不能踢自己，请解散群组'}});
        return result;
    }
    const membersBeforeKick = [...group.members];
    const ok = groupStore.removeMember(groupId, targetUserId);
    if(!ok){
        result.push({type: 'error', data: {code: 400, message: '踢人失败，该用户不是群成员'}});
        return result;
    }
    const targetUser = userStore.findByUserId(targetUserId);
    result.push({type: 'system', data: {text: `已将 ${targetUser?.username ?? targetUserId} 移出群组`}});
    // 通知所有群成员（包括群主自己），除被踢者外
    for(const memberId of membersBeforeKick){
        if(memberId !== targetUserId){
            broadcastTo(memberId, {type: 'group_kick', data: {groupId, targetUserId, targetUsername: targetUser?.username ?? ''}});
        }
    }
    broadcastTo(targetUserId, {type: 'group_self_kicked', data: {groupId, groupName: group.groupName}});
    return result;
}
