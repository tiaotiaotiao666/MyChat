import { webSocket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'

// WebSocket管理器：单例模式，负责连接、断线重连、消息分发、重连后自动登录
// 核心改进：send() 在未连接时将消息入队，连上后自动发送，不再静默丢弃
class WebSocketManager {
  private ws: webSocket.WebSocket | undefined = undefined // 底层WS句柄（undefined=还没创建过连接）
  private url: string = '' // 服务端地址（connect()记下，断线重连要用）
  private isConnect: boolean = false // 连接状态位——send()据此决定"直发"还是"入队"
  private callbacks: ((data: string) => void)[] = [] // 消息监听者列表（观察者：页面各登记一个，每条消息挨个通知）
  private static instance: WebSocketManager // 单例本体：全局唯一那一个实例
  private reconnectTimer: number = -1 // 重连定时器ID（-1=没有排队中的重连，防重复排程）
  private reconnectDelay: number = 3000 // 下次重连间隔毫秒（指数退避：3s→6s→12s…封顶30s）
  private shouldReconnect: boolean = true // 还要不要自动重连（disconnect()置false=主动断，不重连）
  private isConnecting: boolean = false // 正在建连中（connect已发出还没结果）——防连击时反复createConnection
  private isFirstConnect: boolean = true // 是不是第一次连上（首连不算"重连"，不触发重连回调）
  private onReconnectCallback: (() => void) | undefined = undefined // 重连成功后干什么（Index注册=重连后自动登录）
  private openListeners: (() => void)[] = [] // 一次性open监听：连上就触发、然后清空（如"连上后才发登录"）
  // 消息队列：WS未连接时缓存消息，连接成功后批量发送
  private pendingMessages: string[] = []

  // 单例入口：第一次调用才new，之后永远返回同一个实例
  // 为什么单例：全app只允许存在一条WS连接，ChatPage/ChatListPage/Index拿的必须是同一条
  static getInstance(): WebSocketManager {
    if (!WebSocketManager.instance) {
      WebSocketManager.instance = new WebSocketManager()
    }
    return WebSocketManager.instance
  }

  connect(url: string): void {
    // 防重入：已连接或正在建连中，不重复创建
    if (this.isConnect || this.isConnecting) {
      return
    }
    this.url = url
    this.shouldReconnect = true
    // 安全加固：清掉排队中的重连定时器、立即建连——
    // 不然登录页发的第一条消息要等最多30s的重连间隔才发出去，用户只会看到"连接超时"
    if (this.reconnectTimer !== -1) {
      try { clearTimeout(this.reconnectTimer) } catch (e) {}
      this.reconnectTimer = -1
    }
    this.createConnection()
  }

  private createConnection(): void {
    if (this.ws) {
      this.ws.off('open')
      this.ws.off('message')
      this.ws.off('close')
      this.ws.off('error')
      try {
        this.ws.close()
      } catch (e) {
      }
    }

    this.ws = webSocket.createWebSocket()

    // 连接成功
    this.ws.on('open', (error: BusinessError, value: Object) => {
      if (!error) {
        console.info('[WS] 连接成功')
        this.isConnect = true
        this.isConnecting = false
        this.reconnectDelay = 3000
        // 连上后，发送队列中缓存的消息
        this.flushPendingMessages()
        // 触发所有一次性 open 监听（首次+重连都触发，然后清空）
        let listeners = [...this.openListeners]
        this.openListeners = []
        for (let i = 0; i < listeners.length; i++) {
          try { listeners[i]() } catch (e) {}
        }
        if (this.isFirstConnect) {
          this.isFirstConnect = false
        } else {
          if (this.onReconnectCallback !== undefined) {
            this.onReconnectCallback()
          }
        }
      }
    })

    // 收到消息
    this.ws.on('message', (error: BusinessError, value: string | ArrayBuffer) => {
      if (!error) {
        let str = ''
        if (typeof value === 'string') {
          str = value
        } else {
          let buf = value as ArrayBuffer
          let view = new Uint8Array(buf)
          let decoder = util.TextDecoder.create('utf-8')
          str = decoder.decodeToString(view)
        }
        // 安全加固：顶号拦截——服务端踢人前会先发一条kicked再关连接。
        // 必须抢在分发给页面之前拦下：关掉自动重连（否则close后自动重连又拿存档凭据
        // 登回来，跟顶号者互相踢皮球打个没完），再把原因写进AppStorage给页面提示用
        try {
          let parsed = JSON.parse(str) as Record<string, Object>
          if (parsed['type'] === 'kicked') {
            this.shouldReconnect = false
            let kd = parsed['data'] as Record<string, Object>
            let reason = (kd !== undefined && kd['reason'] !== undefined) ? kd['reason'] as string : '账号在其他设备登录'
            AppStorage.setOrCreate('kickReason', reason)
          }
        } catch (e) {
        }
        for (let i = 0; i < this.callbacks.length; i++) {
          this.callbacks[i](str)
        }
      }
    })

    this.ws.on('close', () => {
      console.info('[WS] 连接关闭')
      this.isConnect = false
      this.isConnecting = false
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
    })

    this.ws.on('error', () => {
      console.error('[WS] 连接错误')
      this.isConnect = false
      this.isConnecting = false
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
    })

    try {
      this.isConnecting = true
      this.ws.connect(this.url)
    } catch (e) {
      console.error(`[WS] connect 调用异常: ${JSON.stringify(e)}`)
      this.isConnect = false
      this.isConnecting = false
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
    }
  }

  // 发送队列中缓存的消息
  private flushPendingMessages(): void {
    if (this.pendingMessages.length === 0) {
      return
    }
    // 拷贝后清空队列，防止flush过程中又入队
    let msgs = [...this.pendingMessages]
    this.pendingMessages = []
    for (let i = 0; i < msgs.length; i++) {
      if (this.ws && this.isConnect) {
        try {
          this.ws.send(msgs[i])
        } catch (e) {
          console.error(`[WS] flushPending 发送异常: ${JSON.stringify(e)}`)
        }
      }
    }
  }

  // 排重连定时器：已有排队中的就不重复排；间隔指数退避（3s→6s→…→30s封顶，别把服务器打爆）
  private scheduleReconnect(): void {
    if (this.reconnectTimer !== -1) {
      return
    }
    console.info(`[WS] ${this.reconnectDelay / 1000}秒后重连...`)
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1
      this.createConnection()
    }, this.reconnectDelay) as number

    if (this.reconnectDelay < 30000) {
      this.reconnectDelay = this.reconnectDelay * 2
    }
  }

  // 登记消息监听（观察者模式）：页面把回调交进来，每条WS消息都会挨个调用它们
  // 配套规矩：页面消失必须 removeMessageListener——否则死页面还被回调，带着过期的this乱改状态
  addMessageListener(callback: (data: string) => void): void {
    this.callbacks.push(callback)
  }

  removeMessageListener(callback: (data: string) => void): void {
    let idx = this.callbacks.indexOf(callback)
    if (idx >= 0) {
      this.callbacks.splice(idx, 1)
    }
  }

  // 发送消息：如果WS已连接则直接发，否则入队等连接后发
  send(msg: string): void {
    if (this.ws && this.isConnect) {
      try {
        this.ws.send(msg)
      } catch (e) {
        console.error(`[WS] send 调用异常: ${JSON.stringify(e)}`)
        // 发送失败也入队，等下次重连再发
        this.pendingMessages.push(msg)
      }
    } else {
      // WS未连接，消息入队
      this.pendingMessages.push(msg)
      // 安全加固（Bug12修复）：顺手把连接建起来——以前登出后shouldReconnect被关死，
      // 登录页发的login消息只进队列、永远没人负责重连，表现为"退出登录后再也登不上"
      this.connect(this.url)
    }
  }

  // 清空离线队列：登出这种"会话边界"时必须调——队列里排的是上一个账号发的消息，
  // 换账号登录后被flush出去就串号了
  clearPendingMessages(): void {
    this.pendingMessages = []
  }

  isConnected(): boolean {
    return this.isConnect
  }

  // 注册一次性的 open 监听——连接成功（或重连成功）后触发，然后自动移除
  addOnceOpenListener(callback: () => void): void {
    // 如果已经连接上了，就立即调用
    if (this.isConnect) {
      try { callback() } catch (e) {}
      return
    }
    this.openListeners.push(callback)
  }

  setOnReconnect(callback: (() => void) | undefined): void {
    this.onReconnectCallback = callback
  }

  // 主动断开（退出登录时调）：关掉重连开关 + 清掉排队的重连 + 关连接
  disconnect(): void {
    this.shouldReconnect = false
    if (this.reconnectTimer !== -1) {
      try { clearTimeout(this.reconnectTimer) } catch (e) {}
      this.reconnectTimer = -1
    }
    if (this.ws) {
      try {
        this.ws.close()
      } catch (e) {
        console.error(`[WS] close 调用异常: ${JSON.stringify(e)}`)
      }
    }
  }
}

export default WebSocketManager
