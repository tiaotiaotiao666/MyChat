import * as fs from 'fs';
import * as path from 'path';
import { getFriendInfo } from './users';


export interface JoinRequest{
    from: string;
    nickname: string;
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
export function loadGroups() {
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    if(fs.existsSync(GROUPS_FILE)){
        const raw = fs.readFileSync(GROUPS_FILE, 'utf-8');
        groups = JSON.parse(raw);
        if(groups.length > 0){
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
    if (!group.members.includes(userId)) {
        group.members.push(userId);
        saveGroups();
    }
    return true;
}

export function addJoinRequest(groupId: string, fromUserId: string, nickname: string, avatar: string): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    const exists = group.joinRequests.find(r => r.from === fromUserId && r.status === 'pending');
    if (exists) return false;
    group.joinRequests.push({from :fromUserId, nickname, avatar, status: 'pending' });
    saveGroups();
    return true;
}

export function respondJoinRequest(groupId: string, fromUserId: string, agree: boolean): boolean {
    const group = findByGroupId(groupId);
    if (!group) return false;
    const request = group.joinRequests.find(r => r.from === fromUserId);
    if (!request) return false;
    request.status = agree ? 'accepted' : 'rejected';
    if (agree) {
        addMember(groupId, fromUserId);
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