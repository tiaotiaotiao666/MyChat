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
        result.push({
            type: 'error',
            data: {
                code: 400,
                message: '群组名称不能为空'
            }
        });
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
            groupName: group.groupName
        }
    });
    for(const memberId of group.members){
        if(memberId !== ctx.userId){
            broadcastTo(memberId, {
                type: 'group_invite',
                data: {
                    groupId: group.groupId,
                    groupName: group.groupName,
                    inviterNickname: fromUser.nickname,
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
    const groups = groupStore.searchByGroupName(groupName);
    result.push({
        type: 'group_search_response',
        data: {
            groups: groups.map(g => ({groupId: g.groupId, groupName: g.groupName, owner: g.owner}))
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
    const ok = groupStore.addJoinRequest(groupId, ctx.userId, fromUser.nickname, fromUser.avatar);
    if(!ok){
        result.push({type: 'error', data:{code: 500, message: '已发送过入群申请'}});
        return result;
    }
    result.push({type: 'system', data:{text: `入群申请已发送给群主 ${group.owner}`}});
    broadcastTo(group.owner, {type: 'group_join_request', data: {groupId, groupName: group.groupName, fromUserId: ctx.userId, fromNickname: fromUser.nickname}});
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
    if(group?.owner !== ctx.userId){
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
    result.push({type: 'system', data:{text: `${agree ? '已同意' : '已拒绝'} 入群申请`}});
    broadcastTo(fromUserId, {type: 'group_join_response', data: {groupId, agree}});
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
    result.push({type: 'system', data: {text: '已邀请入群'}})
    broadcastTo(targetUserId, {type: 'group_invite', data: {groupId, groupName: group.groupName, inviterNickname: fromUser.nickname}});
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
    const ok = groupStore.removeMember(groupId, ctx.userId);
    if(!ok){
        result.push({type: 'error', data:{code: 400, message: '退群失败'}});
        return result;
    }
    result.push({type: 'system', data: {text: `已退群`}});
    for(const memberId of group.members){
        if(memberId !== ctx.userId){
            broadcastTo(memberId, {type: 'group_leave', data: {groupId, userId: ctx.userId, nickname: fromUser?.nickname}});
        }
    }
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
    if(group!.owner !== ctx.userId){
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
        if(memberId !== ctx.userId ){
            broadcastTo(memberId, {type: 'group_dissolved', data: {groupId, groupName}});
        }
    }
    return result;
}