import * as fs from 'fs';
import * as path from 'path';

const PRIVATE_DIR = path.join(__dirname, '..', 'data', 'messages', 'private');
const GROUPS_DIR = path.join(__dirname, '..', 'data', 'messages', 'groups');

interface Message{
    messageId: string;
    type: 'private_chat' | 'group_chat' | 'group_private';
    sender: string;
    target: string | null;
    groupId: string | null;
    content: string;
    timestamp: string;
}

let nextMessageId = 3001;
export function loadMessages() {
    if(!fs.existsSync(PRIVATE_DIR)) fs.mkdirSync(PRIVATE_DIR, { recursive: true });
    if(!fs.existsSync(GROUPS_DIR)) fs.mkdirSync(GROUPS_DIR, { recursive: true });
    let maxId = 0;
    for(const file of fs.readdirSync(PRIVATE_DIR)){
        if(!file.endsWith('.json'))continue;
        const msgs = JSON.parse(fs.readFileSync(path.join(PRIVATE_DIR, file), 'utf-8')) as Message[];
        for(const msg of msgs){
            const num = parseInt(msg.messageId.replace('m_', ''));
            if(num > maxId){
                maxId = num;
            }
        }
    }
    for(const file of fs.readdirSync(GROUPS_DIR)){
        if(!file.endsWith('.json'))continue;
        const msgs = JSON.parse(fs.readFileSync(path.join(GROUPS_DIR, file), 'utf-8')) as Message[];
        for(const msg of msgs){
            const num = parseInt(msg.messageId.replace('m_', ''));
            if(num > maxId){
                maxId = num;
            }
        }
    }
    if(maxId > 0) nextMessageId = maxId + 1;
}

function getPrivateMessagesFileName(userId1: string, userId2: string): string {
    const sortedIds = [userId1, userId2].sort();
    return path.join(PRIVATE_DIR, `${sortedIds[0]}_${sortedIds[1]}.json`);
}

export function savePrivateMessage(sender: string, target: string, content: string): Message {
    const msg: Message = {
        messageId: `m_${nextMessageId++}`,
        type: 'private_chat',
        sender,
        target,
        groupId: null,
        content,
        timestamp: new Date().toISOString(),
    };
    const filePath = getPrivateMessagesFileName(sender, target);
    const messages = fs.existsSync(filePath) 
    ? JSON.parse(fs.readFileSync(filePath, 'utf-8')) as Message[]
    : [];
    messages.push(msg);
    if (messages.length > 500) {
        messages.splice(0, messages.length - 500);
    }
    fs.writeFileSync(filePath, JSON.stringify(messages, null, 2), 'utf-8');
    return msg;
}

export function saveGroupMessage(sender: string, groupId: string, content: string, target: string | null = null): Message {
 const msg: Message = {
        messageId: `m_${nextMessageId++}`,
        type: target ? 'group_private' : 'group_chat', 
        sender,
        target,
        groupId,
        content,
        timestamp: new Date().toISOString(),
    };
    const filePath = path.join(GROUPS_DIR, `${groupId}.json`);
    const messages = fs.existsSync(filePath)
        ? JSON.parse(fs.readFileSync(filePath, 'utf-8')) as Message[]
        : [];
    messages.push(msg);
    if (messages.length > 500) {
        messages.splice(0, messages.length - 500);
    }
    fs.writeFileSync(filePath, JSON.stringify(messages, null, 2), 'utf-8');
    return msg;
}

export function getPrivateHistory(userId1: string, userId2: string, count: number = 50): Message[] {
    const filePath = getPrivateMessagesFileName(userId1, userId2);
    if(!fs.existsSync(filePath)) return [];
    const messages = JSON.parse(fs.readFileSync(filePath, 'utf-8')) as Message[];
    return messages.slice(-count);
}

export function getGroupHistory(groupId: string, count: number = 50): Message[] {
    const filePath = path.join(GROUPS_DIR, `${groupId}.json`);
    if(!fs.existsSync(filePath)) return [];
    const messages = JSON.parse(fs.readFileSync(filePath, 'utf-8')) as Message[];
    return messages.slice(-count);
}