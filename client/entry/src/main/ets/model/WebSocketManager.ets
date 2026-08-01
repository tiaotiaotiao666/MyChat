import { webSocket } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'

// WebSocket管理器：单例模式，负责连接、断线重连、消息分发、重连后自动登录
// 核心改进：send() 在未连接时将消息入队，连上后自动发送，不再静默丢弃
class WebSocketManager {
  private ws: webSocket.WebSocket | undefined = undefined
  private url: string = ''
  private isConnect: boolean = false
  private callbacks: ((data: string) => void)[] = []
  private static instance: WebSocketManager
  private reconnectTimer: number = -1
  private reconnectDelay: number = 3000
  private shouldReconnect: boolean = true
  private isFirstConnect: boolean = true
  private onReconnectCallback: (() => void) | undefined = undefined
  private openListeners: (() => void)[] = []
  // 消息队列：WS未连接时缓存消息，连接成功后批量发送
  private pendingMessages: string[] = []

  static getInstance(): WebSocketManager {
    if (!WebSocketManager.instance) {
      WebSocketManager.instance = new WebSocketManager()
    }
    return WebSocketManager.instance
  }

  connect(url: string): void {
    // 防重入：如果正在连接中，不重复创建
    if (this.isConnect) {
      return
    }
    this.url = url
    this.shouldReconnect = true
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
        for (let i = 0; i < this.callbacks.length; i++) {
          this.callbacks[i](str)
        }
      }
    })

    this.ws.on('close', () => {
      console.info('[WS] 连接关闭')
      this.isConnect = false
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
    })

    this.ws.on('error', () => {
      console.error('[WS] 连接错误')
      this.isConnect = false
      if (this.shouldReconnect) {
        this.scheduleReconnect()
      }
    })

    try {
      this.ws.connect(this.url)
    } catch (e) {
      console.error(`[WS] connect 调用异常: ${JSON.stringify(e)}`)
      this.isConnect = false
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
    }
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
