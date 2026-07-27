import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';

export interface FriendRequest{
    from: string;
    nickname: string;
    avatar: string;
    status: 'pending' | 'accepted' | 'rejected';
}

export interface User{
    userId: string;
    username: string;
    password: string;
    nickname: string;
    avatar: string;
    friends: string[];
    friendRequests: FriendRequest[];
    createdAt: string;
}

let users: User[] = [];
let nextUserId = 1001;
const DATA_DIR = path.join(__dirname, '..', 'data');
const USERS_FILE = path.join(DATA_DIR,'users.json');
export function loadUsers(){
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    if(fs.existsSync(USERS_FILE)){
        const raw = fs.readFileSync(USERS_FILE, 'utf-8');
        users = JSON.parse(raw);
        if(users.length > 0){
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
    return crypto.createHash('sha256').update(password).digest('hex');
}

export function verifyPassword(user: User, password: string): boolean {
    return hashPassword(password) === user.password;
}

export function createUser(username: string, password: string, nickname: string, avatar: string): User {
    const user: User = {
        userId: 'u_' + nextUserId,
        username,
        password: hashPassword(password),
        nickname,
        avatar,
        friends: [],
        friendRequests: [],
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
        nickname: fromUser.nickname,
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

export function getFriendInfo(userId: string): { userId: string; nickname: string; avatar: string } | null {
    const user = findByUserId(userId);
    if(!user) return null;
    return {
        userId: user.userId,
        nickname: user.nickname,
        avatar: user.avatar
    };
}

export function getFriendsList(user: User):  Array<{ userId: string; nickname: string; avatar: string }> {
    return user.friends
    .map(fid => getFriendInfo(fid))
    .filter((f): f is {userId: string; nickname: string; avatar: string} => f !== null)
}