// ============================================================
// tokens —— 登录令牌存储（安全加固#8：token保持登录）
// ------------------------------------------------------------
// token是什么：登录成功后服务端发的一张"临时通行证"——一串随机数，
//   客户端保存它，之后重连/重启都凭它换自动登录，不用再发密码。
// 为什么比存密码好：
//   ① 密码是"主凭证"，丢了要改密码；token是"副凭证"，随时可作废重发
//   ② 服务端能单方面吊销（登出即作废），密码做不到"发出去再收回"
//   ③ token泄露只影响当前会话，密码泄露影响账号本体
// 存储策略：内存Map为主 + data/tokens.json落盘（服务重启后token仍有效）；
//   每用户最多留5张（新挤旧），防无限堆积。
// ============================================================
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';

export interface TokenEntry {
    token: string;      // 通行证本体：64个十六进制字符（32字节随机数）
    userId: string;     // 这张证属于谁
    username: string;   // 冗余一份用户名，免得验证时还要查用户表
    createdAt: number;  // 签发时间戳（毫秒）——挤旧和将来做过期都用它
}

let tokens: TokenEntry[] = [];
const DATA_DIR = path.join(__dirname, '..', 'data');
const TOKENS_FILE = path.join(DATA_DIR, 'tokens.json');
const MAX_TOKENS_PER_USER = 5; // 每用户最多几张通行证（手机+平板+模拟器...留5个够用）

function safeReadTokens(): TokenEntry[] {
    if(!fs.existsSync(TOKENS_FILE)) return [];
    const raw = fs.readFileSync(TOKENS_FILE, 'utf-8');
    if(raw.trim() === '') return [];
    return JSON.parse(raw) as TokenEntry[];
}

export function loadTokens(){
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    tokens = safeReadTokens();
}

export function saveTokens(){
    if(!fs.existsSync(DATA_DIR)){
        fs.mkdirSync(DATA_DIR, { recursive: true });
    }
    fs.writeFileSync(TOKENS_FILE, JSON.stringify(tokens, null, 2), 'utf-8');
}

// 签发新token：32字节密码学随机数（猜中概率约2^-256，不用惦记）
export function issueToken(userId: string, username: string): string {
    const token = crypto.randomBytes(32).toString('hex');
    // 同一用户的旧token保留，新的排最后；超过上限挤掉最老的（多设备共存策略）
    tokens = tokens.filter(t => !(t.userId === userId && t.token === token));
    tokens.push({ token, userId, username, createdAt: Date.now() });
    const mine = tokens.filter(t => t.userId === userId);
    if (mine.length > MAX_TOKENS_PER_USER) {
        const oldest = mine.sort((a, b) => a.createdAt - b.createdAt)[0];
        tokens = tokens.filter(t => t.token !== oldest.token);
    }
    saveTokens();
    return token;
}

// 验证：对得上就返回这条记录（里面有userId/username），对不上返回null
export function validateToken(token: string): TokenEntry | null {
    if (!token || token.length !== 64) return null; // 长度都不对就不用翻表
    const entry = tokens.find(t => t.token === token);
    return entry ?? null;
}

// 吊销：登出时用。找不到也不报错——作废一个不存在的证本来就该安静
export function revokeToken(token: string): void {
    tokens = tokens.filter(t => t.token !== token);
    saveTokens();
}
