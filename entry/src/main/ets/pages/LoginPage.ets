// ============================================================
// LoginPage —— 登录/注册页（isRegister切换两态，共用一套UI）
// 流程：前端校验(用户名3-20位/密码≥6位) → 发 login/register → onLoginResp 收结果
// 成功：写AppStorage(账号/好友/群/未读) + preferences存账密(供下次自动登录) → 进主页
// 失败/5秒超时：errorMsg红条提示
// ============================================================
import WebSocketManager from "../model/WebSocketManager"
import { preferences } from '@kit.ArkData'

// ArkTS严格模式禁止使用 unknown/any
// data实际结构随type不同而不同（可能是对象也可能含数组字段），这里统一声明为 Object，访问时使用 as 强转
interface WsMessage {
  type: string
  data: Object
}

const AVATARS: string[] = ['cat', 'dog', 'fox', 'panda', 'rabit', 'robot', 'star', 'youling']

@Component
struct LoginPage {
  @Consume('pageStack') pageStack: NavPathStack // 跳转栈（成功后push ChatListPage）
  @State username: string = '' // 账号输入
  @State password: string = '' // 密码输入
  @State isRegister: boolean = false // false=登录态 / true=注册态（同一页两种皮）
  @State selectedAvatar: string = 'cat' // 注册时选的头像资源名
  @State errorMsg: string = '' // 错误提示红条（空=不显示）

  aboutToAppear(): void {
    // 安全加固：被顶号后ChatListPage会跳转到这里，把原因亮在错误红条上
    // （kickReason由WebSocketManager拦截kicked消息时写入，读完就复位防止下次误报）
    let reason = AppStorage.get<string>('kickReason')
    if (reason !== undefined && reason !== '') {
      this.errorMsg = reason
      AppStorage.setOrCreate('kickReason', '')
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Text(this.isRegister ? '注册账号' : '欢迎登录')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ top: 80, bottom: 8 })
          Text(this.isRegister ? '创建一个新账号开始聊天' : '登录你的MyChat账号')
            .fontSize(14)
            .fontColor('#999999')
            .margin({ bottom: 40 })

          if (this.errorMsg !== '') {
            Row() {
              Text('⚠')
                .fontSize(14)
                .fontColor('#F04848')
                .margin({ right: 6 })
              Text(this.errorMsg)
                .fontSize(14)
                .fontColor('#F04848')
            }
            .width('80%')
            .padding({ top: 8, bottom: 8, left: 12, right: 12 })
            .backgroundColor('#FFF0F0')
            .borderRadius(8)
            .margin({ bottom: 16 })
          }

          TextInput({ placeholder: '用户名', text: this.username })
            .width('80%')
            .height(48)
            .fontSize(16)
            .backgroundColor('#F5F5F5')
            .borderRadius(24)
            .padding({ left: 20, right: 20 })
            .onChange((value: string) => {
              this.username = value
            })

          TextInput({ placeholder: '密码', text: this.password })
            .type(InputType.Password)
            .width('80%')
            .height(48)
            .fontSize(16)
            .backgroundColor('#F5F5F5')
            .borderRadius(24)
            .padding({ left: 20, right: 20 })
            .margin({ top: 16 })
            .onChange((value: string) => this.password = value)

          if (this.isRegister) {
            Text('选择头像')
              .fontSize(16)
              .fontColor('#333333')
              .margin({ top: 28, bottom: 16 })

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
              ForEach(AVATARS, (name: string) => {
                Stack() {
                  Image($r(`app.media.${name}`))
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                  if (this.selectedAvatar === name) {
                    Column() {
                      Text('✓')
                        .fontSize(14)
                        .fontColor(Color.White)
                        .fontWeight(FontWeight.Bold)
                    }
                    .width(20)
                    .height(20)
                    .borderRadius(10)
                    .backgroundColor('#07C160')
                    .position({ x: 40, y: 0 })
                  }
                }
                .width(56)
                .height(56)
                .margin(8)
                .border(this.selectedAvatar === name ? { width: 3, color: '#07C160', radius: 28 } :
                  { width: 0, color: Color.Transparent })
                .onClick(() => {
                  this.selectedAvatar = name
                })
              }, (name: string) => name)
            }
            .width('80%')
          }

          Button(this.isRegister ? '注 册' : '登 录')
            .width('80%')
            .height(48)
            .fontSize(18)
            .fontColor(Color.White)
            .backgroundColor('#07C160')
            .borderRadius(24)
            .margin({ top: 36 })
            .onClick(() => {
              // 前端校验
              if (this.username.trim() === '') {
                this.errorMsg = '请输入用户名'
                return
              }
              if (this.username.length < 3 || this.username.length > 20) {
                this.errorMsg = '用户名长度应在3到20个字符之间'
                return
              }
              if (this.password === '') {
                this.errorMsg = '请输入密码'
                return
              }
              if (this.password.length < 6) {
                this.errorMsg = '密码长度应不少于6个字符'
                return
              }
              this.errorMsg = ''
              let ws = WebSocketManager.getInstance()
              // 超时保护：5秒后如果没收到响应，提示网络错误
              let loginTimeout = setTimeout(() => {
                ws.removeMessageListener(onLoginResp)
                if (this.errorMsg === '') {
                  this.errorMsg = '连接超时，请检查网络或后端是否启动'
                }
              }, 5000)
              let onLoginResp = (data: string) => {
                let msg = JSON.parse(data) as Record<string, Object>
                if (msg['type'] === 'register_response' || msg['type'] === 'login_response') {
                  // 收到响应，清除超时定时器，移除监听
                  clearTimeout(loginTimeout)
                  ws.removeMessageListener(onLoginResp)
                  let msgData = msg['data'] as Record<string, Object>
                  if (msgData['success'] === true) {
                    AppStorage.setOrCreate('userId', msgData['userId'] as string)
                    AppStorage.setOrCreate('username', msgData['username'] as string)
                    AppStorage.setOrCreate('avatar', msgData['avatar'] as string)
                    if (msg['type'] === 'login_response') {
                      AppStorage.setOrCreate('friends', JSON.stringify(msgData['friends']))
                       AppStorage.setOrCreate('groups', JSON.stringify(msgData['groups']))
                       AppStorage.setOrCreate('unreadCounts', JSON.stringify(msgData['unreadCounts'] ?? {}))
                       AppStorage.setOrCreate('friendRequests', JSON.stringify(msgData['friendRequests'] ?? []))
                       AppStorage.setOrCreate('groupJoinRequests', JSON.stringify(msgData['groupJoinRequests'] ?? []))
                       try {
                         let context = AppStorage.get<Context>('context')
                         if (context !== undefined) {
                           let pref = preferences.getPreferencesSync(context, { name: 'loginStore' })
                           pref.putSync('username', this.username)
                           // 安全加固#8：存token不存密码——token丢了可作废重发，密码丢了账号就没了
                           pref.putSync('token', (msgData['token'] ?? '') as string)
                           pref.deleteSync('password') // 兼容清理：老版本存过的明文密码顺手洗掉
                           pref.flush(() => {})
                         }
                       } catch (e) {
                       }
                     } else {
                       // 注册成功：后端register_response现在也返回完整的friends/groups/unreadCounts/friendRequests
                       AppStorage.setOrCreate('friends', JSON.stringify(msgData['friends'] ?? []))
                        AppStorage.setOrCreate('groups', JSON.stringify(msgData['groups'] ?? []))
                        AppStorage.setOrCreate('unreadCounts', JSON.stringify(msgData['unreadCounts'] ?? {}))
                        AppStorage.setOrCreate('friendRequests', JSON.stringify(msgData['friendRequests'] ?? []))
                       AppStorage.setOrCreate('groupJoinRequests', JSON.stringify(msgData['groupJoinRequests'] ?? []))
                      try {
                        let context = AppStorage.get<Context>('context')
                        if (context !== undefined) {
                          let pref = preferences.getPreferencesSync(context, { name: 'loginStore' })
                          pref.putSync('username', this.username)
                          // 安全加固#8：注册成功同样只发token不落密码
                          pref.putSync('token', (msgData['token'] ?? '') as string)
                          pref.deleteSync('password')
                          pref.flush(() => {})
                        }
                      } catch (e) {
                      }
                    }
                    this.pageStack.pushPath({ name: 'ChatListPage' })
                  } else {
                    this.errorMsg = (msgData['error'] ?? msgData['message'] ?? '操作失败') as string
                  }
                } else if (msg['type'] === 'error') {
                  // 错误响应也要处理
                  let msgData = msg['data'] as Record<string, Object>
                  let errMsg = (msgData['message'] ?? '操作失败') as string
                  // 只处理跟登录/注册相关的错误（code 401/403/404等），其他忽略
                  let code = msgData['code'] as number
                  if (code !== undefined && (code === 401 || code === 403 || code === 404 || code === 400)) {
                    clearTimeout(loginTimeout)
                    ws.removeMessageListener(onLoginResp)
                    this.errorMsg = errMsg
                  }
                }
              }
              ws.addMessageListener(onLoginResp)
              if (this.isRegister) {
                let regData: Record<string, string> = {
                  'username': this.username,
                  'password': this.password,
                  'avatar': this.selectedAvatar
                }
                let regMsg: WsMessage = {
                  type: 'register',
                  data: regData
                }
                ws.send(JSON.stringify(regMsg))
              } else {
                let loginData: Record<string, string> = {
                  'username': this.username,
                  'password': this.password
                }
                let loginMsg: WsMessage = {
                  type: 'login',
                  data: loginData
                }
                ws.send(JSON.stringify(loginMsg))
              }
            })

          Text(this.isRegister ? '已有账号？去登录' : '没有账号？去注册')
            .fontSize(14)
            .fontColor('#07C160')
            .margin({ top: 24 })
            .onClick(() => {
              this.isRegister = !this.isRegister
              this.errorMsg = ''
            })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
    }
    .title('MyChat')
    .hideTitleBar(true)
  }
}

@Builder
export function LoginPageBuilder() {
  LoginPage()
}
