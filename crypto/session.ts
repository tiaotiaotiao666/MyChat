// ============================================================
// session —— 每条WS连接的"加密会话"（安全加固#7：应用层传输加密）
// ------------------------------------------------------------
// 密码学方案（两端约定，改任何一处都对不上）：
//   ① 密钥协商：ECDH P-256（双方各生成一对密钥，交换公钥，各自算出
//      相同的共享秘密——这就是 Diffie-Hellman：偷看公钥推不出共享秘密）
//   ② 密钥派生：AES256密钥 = SHA256(共享秘密 || 16字节随机盐)
//   ③ 消息加密：AES-256-GCM（对称加密+认证标签，密文被改一个bit都解不开）
//   ④ 信封格式：data 字段从"明文对象"变成 "ivB64.tagB64.ctB64" 字符串
//      （type 保留明文——路由要看它；iv每条消息随机12字节，绝不复用）
// 为什么不用TLS：TLS把一切包进黑盒，Wireshark里啥也看不到学不到东西；
//   应用层加密全过程可见（握手、密文、篡改测试），教学价值更高。
//   真要上生产：这层外面再套wss/TLS才是标准做法（防中间人）。
// ============================================================
import * as crypto from 'node:crypto';
import { OutgoingMessage } from '../handlers/types';

// 附加认证数据（AAD）：不加密但参与完整性校验的固定字节，两端必须一致
const AAD = Buffer.from('MyChatSecureAAD1', 'utf8'); // 恰好16字节

export class SessionCrypto {
    private key: Buffer; // AES-256会话密钥（32字节），只在内存里，绝不落盘

    private constructor(key: Buffer) {
        this.key = key;
    }

    // 服务端侧的握手：拿客户端公钥，生成自己的密钥对，算出共享秘密并派生会话密钥
    static establish(clientPubB64: string): { response: { pub: string; salt: string }; session: SessionCrypto } {
        // prime256v1 就是 P-256（名字不同而已，NIST曲线）
        const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
        const clientPub = crypto.createPublicKey({
            key: Buffer.from(clientPubB64, 'base64'),
            format: 'der',
            type: 'spki', // 客户端发来的是X.509/SPKI格式DER
        });
        // ECDH核心一步：我的私钥 + 对方公钥 = 共享秘密（对方用它自己的私钥+我的公钥算出同一个值）
        const shared = crypto.diffieHellman({ privateKey, publicKey: clientPub });
        const salt = crypto.randomBytes(16);
        const key = crypto.createHash('sha256').update(Buffer.concat([shared, salt])).digest();
        return {
            response: {
                pub: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
                salt: salt.toString('base64'),
            },
            session: new SessionCrypto(key),
        };
    }

    // 出站：把整条消息的data字段加密成 "iv.tag.ct" 信封
    // 返回类型单独声明：线上格式的data是字符串，和内存里"对象形态"的OutgoingMessage不同
    encryptMsg(msg: OutgoingMessage): { type: string; data: string } {
        const iv = crypto.randomBytes(12); // GCM标准推荐96位IV，每条消息现生成
        const cipher = crypto.createCipheriv('aes-256-gcm', this.key, iv);
        cipher.setAAD(AAD);
        const ct = Buffer.concat([cipher.update(JSON.stringify(msg.data), 'utf8'), cipher.final()]);
        const tag = cipher.getAuthTag(); // 16字节认证标签
        return {
            type: msg.type,
            data: `${iv.toString('base64')}.${tag.toString('base64')}.${ct.toString('base64')}`,
        };
    }

    // 入站：解开 "iv.tag.ct" 信封，还原data对象；密文被动过会在这里抛异常
    decryptData(data: unknown): Record<string, unknown> {
        const parts = String(data).split('.');
        if (parts.length !== 3) {
            throw new Error('密文信封格式错误');
        }
        const decipher = crypto.createDecipheriv('aes-256-gcm', this.key, Buffer.from(parts[0], 'base64'));
        decipher.setAAD(AAD);
        decipher.setAuthTag(Buffer.from(parts[1], 'base64'));
        const plain = Buffer.concat([
            decipher.update(Buffer.from(parts[2], 'base64')),
            decipher.final(), // 认证标签对不上时这一步直接抛错——这就是GCM的防篡改
        ]).toString('utf8');
        return JSON.parse(plain);
    }
}
