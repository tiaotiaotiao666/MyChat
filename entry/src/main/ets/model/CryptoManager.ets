// ============================================================
// CryptoManager —— 每条WS连接一把的"加密会话"管理器（安全加固#7）
// ------------------------------------------------------------
// 职责：① 连接建立后发起ECC密钥协商（beginHandshake）
//      ② 收到服务端握手回执后派生AES会话密钥（onServerHello）
//      ③ 之后 encrypt()/decrypt() 包办所有消息的加解密
// 和服务端 crypto/session.ts 是一对——以下常量两端必须一致：
//   曲线ECC256(即P-256) / 密钥=SHA256(共享秘密||盐) / AES-256-GCM / AAD='MyChatSecureAAD1'
// 密码学小课堂（为什么要这一层）：
//   ECDH让双方在"全程被偷看"的信道上协商出只有他俩知道的密钥——
//   偷看者拿得到两边公钥，但数学上推不出共享秘密（椭圆曲线离散对数难题）；
//   GCM不但加密还自带"防伪签"（authTag），密文被改一个bit解密时就直接报错。
// 线上信封格式：{ type: 原类型明文, data: "ivB64.tagB64.ctB64" }
//   type保留明文——消息路由要看它；iv每条消息独立，绝不复用。
// ============================================================
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

// 两端约定一致的AAD：不加密但参与完整性校验（相当于给密文贴封条），恰好16字节
const AAD_TEXT: string = 'MyChatSecureAAD1'

export default class CryptoManager {
  private ready: boolean = false // 握手完成标志——没握上前消息一律排队，绝不裸奔
  private priKey: cryptoFramework.PriKey | undefined = undefined // 自己的ECC私钥（只用来算共享秘密，绝不上传）
  private aesKey: cryptoFramework.SymKey | undefined = undefined // 会话密钥：加解密全靠它
  private ivPool: Uint8Array[] = [] // IV池：握手时一次取768字节随机数，切成64个12字节IV
  // 为什么用池子：取随机数的接口是异步的，逐条取会把send()拖成异步链；
  // 提前备好64条，用完在下一次encrypt开头异步补，既保证"IV绝不复用"又不打断发送节奏
  private onReadyCb: (() => void) | undefined = undefined // 握手完成回调（WebSocketManager注册）

  setOnReady(cb: (() => void) | undefined): void {
    this.onReadyCb = cb
  }

  isReady(): boolean {
    return this.ready
  }

  // 每条新连接都要重置：旧连接的密钥/IV池整体作废（会话密钥绝不能跨连接复用）
  reset(): void {
    this.ready = false
    this.priKey = undefined
    this.aesKey = undefined
    this.ivPool = []
  }

  // ① 发起握手：生成ECC密钥对，把公钥（X.509/SPKI格式）发给服务端
  async beginHandshake(sendRaw: (s: string) => void): Promise<void> {
    this.reset()
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256') // ECC256 = P-256曲线
    const pair = await generator.generateKeyPair()
    this.priKey = pair.priKey // 私钥留在本机，谁也不给——给了就等于密码学身份被盗
    const pubBlob = pair.pubKey.getEncoded() // 公钥序列化成SPKI DER字节
    let pubB64 = new util.Base64Helper().encodeToStringSync(pubBlob.data)
    let data: Record<string, string> = { 'pub': pubB64 }
    let msg: Record<string, Object> = { 'type': 'key_exchange', 'data': data }
    sendRaw(JSON.stringify(msg))
  }

  // ② 收到服务端回执{pub, salt}：算共享秘密→派生AES密钥→备好IV池→就绪
  async onServerHello(raw: string): Promise<void> {
    let msg = JSON.parse(raw) as Record<string, Object>
    let hello = msg['data'] as Record<string, string>
    // 服务端公钥从base64还原成密钥对象（convertKey认的就是X.509/SPKI格式）
    let pubBytes = new util.Base64Helper().decodeSync(hello['pub'])
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256')
    let pubBlob: cryptoFramework.DataBlob = { data: pubBytes }
    const kp = await generator.convertKey(pubBlob, null)
    // ECDH核心一步：我的私钥 + 对方公钥 = 共享秘密（服务端用它私钥+我公钥算出同一个值）
    // 先把私钥收窄成非空局部变量——带着undefined联合类型去调重载方法，ArkTS会解析失败
    const pri = this.priKey
    if (pri === undefined) {
      throw new Error('私钥丢失，握手状态异常')
    }
    const agreement = cryptoFramework.createKeyAgreement('ECC256')
    const secret = await agreement.generateSecret(pri, kp.pubKey)
    // 密钥派生：SHA256(共享秘密 || 16字节盐)——掺盐让每次握手的密钥都不一样
    let saltBytes = new util.Base64Helper().decodeSync(hello['salt'])
    const md = cryptoFramework.createMd('SHA-256')
    await md.update({ data: this.concatBytes(secret.data, saltBytes) })
    const digest = await md.digest()
    const symGen = cryptoFramework.createSymKeyGenerator('AES256')
    let keyBlob: cryptoFramework.DataBlob = { data: digest.data }
    this.aesKey = await symGen.convertKey(keyBlob)
    // 预生成64个12字节IV（GCM推荐96位IV）
    const rand = cryptoFramework.createRandom()
    const bigBlob = await rand.generateRandom(64 * 12)
    this.ivPool = this.splitBytes(bigBlob.data, 12)
    this.ready = true
    if (this.onReadyCb !== undefined) {
      this.onReadyCb()
    }
  }

  // ③ 出站加密：入参是页面拼好的完整消息JSON，返回信封JSON
  async encrypt(plainJson: string): Promise<string> {
    if (!this.ready || this.aesKey === undefined) {
      throw new Error('会话未就绪，不能加密')
    }
    if (this.ivPool.length === 0) {
      await this.refillIvPool() // 池子见底：异步补一批再继续（保证IV绝不复用）
    }
    let parsed = JSON.parse(plainJson) as Record<string, Object>
    let type = parsed['type'] as string
    let plainBytes = new util.TextEncoder().encodeInto(JSON.stringify(parsed['data']))
    const iv = this.ivPool.shift() as Uint8Array
    let cipher = cryptoFramework.createCipher('AES256|GCM|NO_PADDING') // GCM是流式模式，不需要padding
    let gcmParams = this.makeGcmParams(iv, new Uint8Array(16)) // 加密时authTag位传16字节占位0
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.aesKey, gcmParams)
    const out = await cipher.doFinal({ data: plainBytes })
    // OHOS的GCM加密结果 = 密文 || 16字节tag（拼在末尾），拆开分别装信封
    let ct = out.data.slice(0, out.data.length - 16)
    let tag = out.data.slice(out.data.length - 16)
    let b64 = new util.Base64Helper()
    let envelopeData = `${b64.encodeToStringSync(iv)}.${b64.encodeToStringSync(tag)}.${b64.encodeToStringSync(ct)}`
    let msg: Record<string, Object> = { 'type': type, 'data': envelopeData }
    return JSON.stringify(msg)
  }

  // ③ 入站解密：入参是信封JSON，返回还原后的完整消息JSON
  async decrypt(wireJson: string): Promise<string> {
    if (!this.ready || this.aesKey === undefined) {
      throw new Error('会话未就绪，收到密文')
    }
    let msg = JSON.parse(wireJson) as Record<string, Object>
    let envelopeData = msg['data'] as string
    let parts = envelopeData.split('.')
    if (parts.length !== 3) {
      throw new Error('信封格式错误')
    }
    let b64 = new util.Base64Helper()
    let iv = b64.decodeSync(parts[0])
    let tag = b64.decodeSync(parts[1])
    let ct = b64.decodeSync(parts[2])
    let cipher = cryptoFramework.createCipher('AES256|GCM|NO_PADDING')
    let gcmParams = this.makeGcmParams(iv, tag) // 解密时authTag位传真实tag
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.aesKey, gcmParams)
    const out = await cipher.doFinal({ data: ct }) // tag对不上这里直接抛错——防篡改就靠它
    let dataJson = util.TextDecoder.create('utf-8').decodeToString(out.data) // TextDecoder.create是静态工厂，不用new
    let dataObj = JSON.parse(dataJson) as Record<string, Object>
    let restored: Record<string, Object> = { 'type': msg['type'] as string, 'data': dataObj }
    return JSON.stringify(restored)
  }

  // ---- 私有工具 ----

  // IV池见底时补一批（encrypt里await调用，不阻塞主流程）
  private async refillIvPool(): Promise<void> {
    const rand = cryptoFramework.createRandom()
    const bigBlob = await rand.generateRandom(64 * 12)
    this.ivPool = this.splitBytes(bigBlob.data, 12)
  }

  // 组装GCM参数：iv(12B) + aad(16B固定) + authTag(16B，加密传占位/解密传真实值)
  private makeGcmParams(iv: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    let aadBytes = new util.TextEncoder().encodeInto(AAD_TEXT)
    let params: cryptoFramework.GcmParamsSpec = {
      iv: { data: iv },
      aad: { data: aadBytes },
      authTag: { data: authTag },
      algName: 'GcmParamsSpec'
    }
    return params
  }

  // 把一大段随机字节按ivLen切成若干份
  private splitBytes(all: Uint8Array, ivLen: number): Uint8Array[] {
    let pool: Uint8Array[] = []
    for (let i = 0; i + ivLen <= all.length; i += ivLen) {
      pool.push(all.slice(i, i + ivLen))
    }
    return pool
  }

  // 拼接两段字节（共享秘密||盐 → 一起喂给SHA256）
  private concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    let out = new Uint8Array(a.length + b.length)
    out.set(a, 0)
    out.set(b, a.length)
    return out
  }
}
