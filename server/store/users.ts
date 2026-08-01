import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';

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
    if(!fs.existsSync(USERS_FILE)) return [];
    const raw = fs.readFileSync(USERS_FILE, 'utf-8');
    if(raw.trim() === '') return [];
    return JSON.parse(raw) as User[];
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
    fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), 'utf-8');
}

export function findByUsername(username: string): User | undefined {
    return users.find(u => u.username === username);
}

export function findByUserId(userId: string): User | undefined {
    return users.find(u => u.userId === userId);
}

export function hashPassword(password: string): string {
    const salt = crypto.randomBytes(16).toString('hex');
    const digest = crypto.createHash('sha256').update(salt + password).digest('hex');
    return `${salt}:${digest}`;
}

export function verifyPassword(user: User, password: string): boolean {
    const stored = user.password || '';
    const idx = stored.indexOf(':');
    if (idx <= 0) {
        return crypto.createHash('sha256').update(password).digest('hex') === stored;
    }
    const salt = stored.slice(0, idx);
    const expectDigest = stored.slice(idx + 1);
    const actualDigest = crypto.createHash('sha256').update(salt + password).digest('hex');
    return actualDigest === expectDigest;
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
