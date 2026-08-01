import * as fs from 'fs';
import * as path from 'path';
import { getFriendInfo } from './users';


export interface JoinRequest{
    from: string;
    username: string;
    avatar: string;
    status: 'pending' | 'accepted' | 'rejected';
}

export interface Group{
    groupName: string;
    groupId: string;
    owner: string;
    members: string[];
    joinRequests: JoinRequest[];
    createdAt: string;
}

let groups: Group[] = [];
let nextGroupId = 2001;
const DATA_DIR = path.join(__dirname, '..', 'data');
const GROUPS_FILE = path.join(DATA_DIR,'groups.json');

function safeReadGroups(): Group[] {
    if(!fs.existsSync(GROUPS_FILE)) return [];
    const raw = fs.readFileSync(GROUPS_FILE, 'utf-8');
    if(raw.trim() === '') return [];
    return JSON.parse(raw) as Group[];
}

export function loadGroups() {
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    const loaded = safeReadGroups();
    if(loaded.length > 0){
        groups = loaded;
        let maxId = 0;
        for(const g of groups){
            const num = parseInt(g.groupId.replace('g_', ''));
            if(num > maxId){
                maxId = num;
            }
        }
        nextGroupId = maxId + 1;
    }
}

export function saveGroups() {
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(GROUPS_FILE, JSON.stringify(groups, null, 2), 'utf-8');
}

export function findByGroupId(groupId: string): Group | undefined {
    return groups.find(group => group.groupId === groupId);
}

export function searchByGroupName(groupName: string): Group[] {
    return groups.filter(group => group.groupName.includes(groupName));
}

export function existsByGroupName(groupName: string): boolean {
    return groups.some(group => group.groupName === groupName);
}

export function createGroup(groupName: string, owner: string, memberIds: string[]) {
    const group: Group = {
        groupId: 'g_' + nextGroupId,
        groupName,
        owner,
        members: [...new Set([owner, ...memberIds])],
        joinRequests: [],
        createdAt: new Date().toISOString(),
    };
    groups.push(group);
    nextGroupId++;
    saveGroups();
    return group;
}

export function isMember(groupId: string, userId: string): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    return group.members.includes(userId);
}

export function addMember(groupId: string, userId: string): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    // 修复BUG#3：用户已在群中应返回false，否则 handleGroupInvite 会误判"邀请成功"并重复发通知
    if (group.members.includes(userId)) {
        return false;
    }
    group.members.push(userId);
    saveGroups();
    return true;
}

export function addJoinRequest(groupId: string, fromUserId: string, username: string, avatar: string): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    const exists = group.joinRequests.find(r => r.from === fromUserId && r.status === 'pending');
    if (exists) return false;
    group.joinRequests.push({from :fromUserId, username, avatar, status: 'pending' });
    saveGroups();
    return true;
}

export function respondJoinRequest(groupId: string, fromUserId: string, agree: boolean): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    const request = group.joinRequests.find(r => r.from === fromUserId && r.status === 'pending');
    if (!request) return false;
    request.status = agree ? 'accepted' : 'rejected';
    if (agree) {
        addMember(groupId, fromUserId);
        // addMember 内部已调用 saveGroups，跳过外层重复保存
        return true;
    }
    saveGroups();
    return true;
}

export function removeMember(groupId: string, userId: string): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    const index = group.members.indexOf(userId);
    if (index !== -1) {
        group.members.splice(index, 1);
        saveGroups();
        return true;
    }
    return false;
}

export function dissolveGroup(groupId: string): boolean {
    const index = groups.findIndex(group => group.groupId === groupId);
    if (index !== -1) {
        groups.splice(index, 1);
        saveGroups();
        return true;
    }
    return false;
}

export function getPendingJoinRequestsForOwner(userId: string): Array<{ groupId: string; groupName: string; from: string; username: string; avatar: string }> {
    const result: Array<{ groupId: string; groupName: string; from: string; username: string; avatar: string }> = [];
    for (const group of groups) {
        if (group.owner !== userId) continue;
        for (const req of group.joinRequests) {
            if (req.status === 'pending') {
                result.push({ groupId: group.groupId, groupName: group.groupName, from: req.from, username: req.username, avatar: req.avatar });
            }
        }
    }
    return result;
}

export function getGroupsForUser(userId: string): Array<{ groupId: string; groupName: string; owner: string; ownerAvatar: string; members: string[] }> {
    return groups
        .filter(group => group.members.includes(userId))
        .map(group => {
            const ownerInfo = getFriendInfo(group.owner);
            return {
                groupId: group.groupId,
                groupName: group.groupName,
                owner: group.owner,
                ownerAvatar: ownerInfo?.avatar ?? '',
                members: group.members,
        };
        });
}
