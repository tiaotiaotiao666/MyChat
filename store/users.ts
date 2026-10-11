import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import { atomicWriteFileSync, safeReadJson } from './fsutil';

export interface FriendRequest{
    from: string;
    username: string;
    avatar: string;
    status: 'pending' | 'accepted' | 'rejected';
}

export interface User{
    userId: string;
    username: string;
    password: string;
    avatar: string;
    friends: string[];
    friendRequests: FriendRequest[];
    unreadCounts: Record<string, number>;
    createdAt: string;
}

let users: User[] = [];
let nextUserId = 1001;
const DATA_DIR = path.join(__dirname, '..', 'data');
const USERS_FILE = path.join(DATA_DIR,'users.json');

function safeReadUsers(): User[] {
    return safeReadJson<User[]>(USERS_FILE, []);
}

export function loadUsers(){
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    const loaded = safeReadUsers();
    if(loaded.length > 0){
        users = loaded;
        let maxId = 0;
        for(const u of users){
            const num = parseInt(u.userId.replace('u_', ''));
            if(num > maxId){
                maxId = num;
            }
        }
        nextUserId = maxId + 1;
    }
}

export function saveUsers(){
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    atomicWriteFileSync(USERS_FILE, JSON.stringify(users, null, 2)); // 安全加固#9：原子写盘
}

export function findByUsername(username: string): User | undefined {
    return users.find(u => u.username === username);
}

export function findByUserId(userId: string): User | undefined {
    return users.find(u => u.userId === userId);
}

// 安全加固#9：密码哈希升级为 scrypt——专门为存密码设计的"慢+吃内存"哈希，
// GPU暴力破解成本比单轮SHA-256高几个数量级。参数 N=16384/r=8/p=1（Node推荐默认）
// 存储格式进化史：无盐sha256（最早）→ "salt:sha256"（v1）→ "scrypt:salt:digest"（v2现行）
export function hashPassword(password: string): string {
    const salt = crypto.randomBytes(16).toString('hex');
    const digest = crypto.scryptSync(password, salt, 32, { N: 16384, r: 8, p: 1 }).toString('hex');
    return `scrypt:${salt}:${digest}`;
}

// 验证密码：按存储格式自动识别三代，老账号也能继续登录
// 三代格式：无盐sha256（第一代）→ "salt:sha256"（第二代）→ "scrypt:salt:digest"（第三代现行）
export function verifyPassword(user: User, password: string): boolean {
    const stored = user.password || '';
    if (!stored.includes(':')) {
        // 第一代：无盐裸sha256（历史遗留，登录成功后会被透明升级）
        return crypto.createHash('sha256').update(password).digest('hex') === stored;
    }
    const parts = stored.split(':');
    if (parts[0] === 'scrypt') {
        // 第三代（现行）：scrypt:salt:digest
        const salt = parts[1], digest = parts[2];
        if (!digest || digest.length !== 64) return false;
        const test = crypto.scryptSync(password, salt, 32, { N: 16384, r: 8, p: 1 });
        // timingSafeEqual：恒时比较——连"比较耗时"这条侧信道都不给攻击者
        return crypto.timingSafeEqual(test, Buffer.from(digest, 'hex'));
    }
    // 第二代：salt:sha256（第一段是盐，冒号后是摘要）
    const salt = stored.slice(0, stored.indexOf(':'));
    const expectDigest = stored.slice(stored.indexOf(':') + 1);
    const actualDigest = crypto.createHash('sha256').update(salt + password).digest('hex');
    return actualDigest === expectDigest;
}

// 登录成功后调用：老格式账号透明升级到scrypt（用户无感，从此存的就是新格式）
export function upgradePasswordIfNeeded(user: User, plainPassword: string): void {
    if (user.password.startsWith('scrypt:')) return;
    user.password = hashPassword(plainPassword);
    saveUsers();
}

export function createUser(username: string, password: string, avatar: string): User {
    const user: User = {
        userId: 'u_' + nextUserId,
        username,
        password: hashPassword(password),
        avatar,
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

export function addFriend(userId: string, friendId: string): boolean {
    const user = findByUserId(userId);
    const friend = findByUserId(friendId);
    if (!user || !friend) return false;       
    if (user.friends.includes(friendId)) return false;  
    user.friends.push(friendId);   
    friend.friends.push(userId);   
    saveUsers();
    return true;
}

export function addFriendRequest(fromUser: User, toUser: User): boolean {
    const exits = toUser.friendRequests.find(r => r.from === fromUser.userId && r.status === 'pending');
    if (exits) return false;
    toUser.friendRequests.push({
        from: fromUser.userId,
        username: fromUser.username,
        avatar: fromUser.avatar,
        status: 'pending'
    });
    saveUsers();
    return true;
}

export function respondFriendRequest(toUser: User, fromUserId: string, agree: boolean): boolean { 
    const req = toUser.friendRequests.find(r => r.from === fromUserId && r.status === 'pending');
    if(!req) return false;
    req.status = agree ? 'accepted' : 'rejected';
    if(agree){
        addFriend(toUser.userId, fromUserId);
        return true;
    }
    saveUsers();
    return true;
}

export function deleteFriend(userId: string, friendId: string): boolean { 
    const user = findByUserId(userId);
    const friend = findByUserId(friendId);
    if (!user || !friend) return false;       
    user.friends = user.friends.filter(f => f !== friendId);   
    friend.friends = friend.friends.filter(f => f !== userId);   
    saveUsers();
    return true;
}

export function getFriendInfo(userId: string): { userId: string; username: string; avatar: string } | null {
    const user = findByUserId(userId);
    if(!user) return null;
    return {
        userId: user.userId,
        username: user.username,
        avatar: user.avatar
    };
}

export function getFriendsList(user: User):  Array<{ userId: string; username: string; avatar: string }> {
    return user.friends
    .map(fid => getFriendInfo(fid))
    .filter((f): f is {userId: string; username: string; avatar: string} => f !== null)
}

export function incrementUnread(userId: string, targetId: string): void {
    const user = findByUserId(userId);
    if(!user) return;
    if(!user.unreadCounts) user.unreadCounts = {};
    user.unreadCounts[targetId] = (user.unreadCounts[targetId] || 0) + 1;
    saveUsers();
}

export function clearUnread(userId: string, targetId: string): void {
    const user = findByUserId(userId);
    if(!user) return;
    if(!user.unreadCounts) user.unreadCounts = {};
    user.unreadCounts[targetId] = 0;
    saveUsers();
}

export function getUnreadCounts(userId: string): Record<string, number> {
    const user = findByUserId(userId);
    if(!user || !user.unreadCounts) return {};
    return user.unreadCounts;
}
