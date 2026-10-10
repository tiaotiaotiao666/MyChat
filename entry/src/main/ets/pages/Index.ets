// ============================================================
// Index —— 应用真正的入口页（@Entry，router的第一个页面）
// 职责：① 连WS（服务端地址在下面"部署配置区"）② 自动登录（读preferences存的账密）
// 去向：登录成功→ChatListPage ；失败/没存账密→LoginPage
// 三层防卡死：3秒登录超时、WS连上后200ms兜底、800ms极端兜底（细节见下方注释）
// Navigation容器 + @Provide pageStack：全app的跳转栈从这里发下去
// ============================================================
import WebSocketManager from '../model/WebSocketManager'
import { preferences } from '@kit.ArkData'

// ====== 部署配置区 ======
// WebSocket 服务端地址：默认使用当前本机的局域网IP
// ⚠️ 注意：
//   - 模拟器访问宿主机：直接使用宿主机的局域网IP（如当前配置），请确保 Windows 防火墙已放行 3500 端口
//   - 真机调试：请将下方地址改为后端实际可访问的地址（如服务器公网IP或同网段局域网IP）
//   - 本机 DevEco 预览器：如果连不上 192.x 段，可以尝试换成 ws://127.0.0.1:3500 或 ws://10.0.2.2:3500
//   - 如果更换了Wi-Fi/网络环境，本机IP会变化！请在 PowerShell 里用 `ipconfig` 查看最新 WLAN IPv4 地址，修改下方常量
// const WS_SERVER_URL: string = 'wss://frp-put.com:58963'
// =========================
const WS_SERVER_URL: string = 'ws://172.23.192.1:3500'

@Entry
@Component
struct Index {
  @Provide('pageStack') pageStack: NavPathStack = new NavPathStack() // 全app跳转栈：子页面用@Consume('pageStack')消费同一份

  // 防止多次跳页的标志位
  private pagePushed: boolean = false

  private pushIfEmpty(name: string): void {
    if (this.pagePushed) {
      return
    }
    if (this.pageStack.size() === 0) {
      this.pagePushed = true
      this.pageStack.pushPath({ name: name })
    } else {
      this.pagePushed = true
    }
  }

  aboutToAppear(): void {
    let ws = WebSocketManager.getInstance()
    ws.connect(WS_SERVER_URL)

    let savedUsername: string = ''
    let savedPassword: string = ''
    try {
      let context = AppStorage.get<Context>('context')
      if (context !== undefined) {
        let pref = preferences.getPreferencesSync(context, { name: 'loginStore' })
        savedUsername = pref.getSync('username', '') as string
        savedPassword = pref.getSync('password', '') as string
      }
    } catch (e) {
    }

    let hasSavedLogin = savedUsername !== '' && savedPassword !== ''

    // 自动登录回调——只处理一次，不管成功失败都移除
    let autoLoginCallback = (data: string): void => {
      let msg = JSON.parse(data) as Record<string, Object>
      if (msg['type'] === 'login_response') {
        let msgData = msg['data'] as Record<string, Object>
        // 无论成功失败，都移除这个回调，不再拦截后续消息
        ws.removeMessageListener(autoLoginCallback)
        // 收到login响应时，顺手清掉登录超时定时器
        if (loginTimeoutTimer !== -1) {
          try { clearTimeout(loginTimeoutTimer) } catch (e) {}
          loginTimeoutTimer = -1
        }
        if (msgData['success'] === true) {
          AppStorage.setOrCreate('userId', msgData['userId'] as string)
          AppStorage.setOrCreate('username', msgData['username'] as string)
          AppStorage.setOrCreate('avatar', msgData['avatar'] as string)
          AppStorage.setOrCreate('friends', JSON.stringify(msgData['friends']))
          AppStorage.setOrCreate('groups', JSON.stringify(msgData['groups']))
          AppStorage.setOrCreate('unreadCounts', JSON.stringify(msgData['unreadCounts'] ?? {}))
          AppStorage.setOrCreate('friendRequests', JSON.stringify(msgData['friendRequests'] ?? []))
          AppStorage.setOrCreate('groupJoinRequests', JSON.stringify(msgData['groupJoinRequests'] ?? []))
          this.pushIfEmpty('ChatListPage')
        } else {
          // 登录失败，跳登录页让用户手动操作
          this.pushIfEmpty('LoginPage')
        }
      }
    }

    // 重连后的自动登录回调——同样只处理一次
    let loginTimeoutTimer: number = -1
    let autoLoginInFlight: boolean = false // Bug3修复：标记login请求已发起（防止800ms兜底打断）
    let doAutoLogin = (): void => {
      if (!hasSavedLogin) {
        this.pushIfEmpty('LoginPage')
        return
      }
      let currentUserId = AppStorage.get<string>('userId')
      if (currentUserId !== undefined && currentUserId !== '') {
        // userId已经存在，直接进主页，不要return什么都不做
        this.pushIfEmpty('ChatListPage')
        return
      }
      ws.addMessageListener(autoLoginCallback)
      autoLoginInFlight = true
      let loginData: Record<string, string> = {
        'username': savedUsername,
        'password': savedPassword
      }
      let loginMsg: Record<string, Object> = {
        'type': 'login',
        'data': loginData
      }
      ws.send(JSON.stringify(loginMsg))

      // 登录请求短超时：3秒没收到login_response就强制跳登录页（避免一直等，800ms兜底只做极端卡住的保护）
      if (loginTimeoutTimer !== -1) {
        try { clearTimeout(loginTimeoutTimer) } catch (e) {}
      }
      loginTimeoutTimer = setTimeout(() => {
        loginTimeoutTimer = -1
        autoLoginInFlight = false
        if (!this.pagePushed) {
          ws.removeMessageListener(autoLoginCallback)
          this.pushIfEmpty('LoginPage')
        }
      }, 3000) as number
    }

    // 兜底1：WS连上后，如果还没跳页（说明login消息还在队列里/或者被吞了），再触发一次doAutoLogin判断
    let openCallback = (): void => {
      setTimeout(() => {
        if (!this.pagePushed) {
          doAutoLogin()
        }
      }, 200)
    }
    ws.addOnceOpenListener(openCallback)

    // 兜底2：800ms——仅用于极端情况下WS初始化/连接卡住（根本没连上、也没有发起任何请求）时强制进LoginPage
    // Bug3修复：如果已经发起了login请求（autoLoginInFlight=true）或userId已存在，则跳过，防止打断正常登录
    setTimeout(() => {
      if (!this.pagePushed) {
        let currentUserId = AppStorage.get<string>('userId')
        if ((currentUserId !== undefined && currentUserId !== '') || autoLoginInFlight) {
          // 正常登录流已启动，交给内部 3000ms timeout 保护
          return
        }
        ws.removeMessageListener(autoLoginCallback)
        if (loginTimeoutTimer !== -1) {
          try { clearTimeout(loginTimeoutTimer) } catch (e) {}
          loginTimeoutTimer = -1
        }
        this.pushIfEmpty('LoginPage')
      }
    }, 800)

    ws.setOnReconnect(doAutoLogin)
    doAutoLogin()
  }

  build() {
    Navigation(this.pageStack) {
    }
    .width('100%')
    .height('100%')
  }
}
