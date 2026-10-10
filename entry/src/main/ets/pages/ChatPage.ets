// ============================================================
// ChatPage —— 聊天详情页（单个会话的对话界面）
// ------------------------------------------------------------
// 职责：收发"当前这个会话"的消息 + 渲染气泡列表
// 发送流（Bug5乐观插入）：sendMessage本地先插一条(带clientId"待确认") → ws发服务端
//   → 回 *_sent成功 → confirmOldestPending换上服务端真实时间
//   → 回 error失败 → rollbackOldestPending把假消息撤下桌
// 接收流：WS消息 → messageHandler(箭头类字段，终生绑this) → onMessage按type分发
// Bug11：群内私信——点头像/昵称进私信模式(privateTarget非null)，发完自动退出防误发
// 状态管理：V1——@State数组内属性原地改不刷新，改消息列表要整体替换/clone
// 工厂改造进度：顶部import已接入Message类、历史加载已走工厂；
//   实时消息 / 本地插入 / 渲染 三处还是老写法【Step 2 待接线】
// ============================================================
import WebSocketManager from '../model/WebSocketManager'
import { Conversation } from '../model/Conversation'
import { ChatMessage, TextMessage, GroupPrivateMessage, SystemMessage, MessageFactory } from '../model/Message'

// Bug11：群内私信的目标对象（记着"我在给谁发私聊"）
interface PrivateTarget {
  userId: string
  username: string
  avatar: string
}

// 生成简单uuid（前端临时ID，够unique就行）
function simpleClientId(): string {
  return 'c_' + Date.now().toString(36) + '_' + Math.floor(Math.random() * 1000000).toString(36)
}

@Component
struct ChatPage {
  @Consume('pageStack') pageStack: NavPathStack // 跳转栈（Index @Provide的，push/pop换页）
  @State messages: ChatMessage[] = [] // 消息列表——渲染的唯一数据源
  @State inputText: string = '' // 输入框当前文字
  @State targetName: string = '' // 标题栏显示的对方昵称/群名
  // Bug11：群聊模式下的私信目标（不为空表示当前正在给XX发群内私信）
  @State privateTarget: PrivateTarget | null = null
  private conversation: Conversation = new Conversation() // 当前会话身份（入栈参数：type/targetId/name）
  private scroller: Scroller = new Scroller() // 列表滚动控制器（scrollToBottom用）
  // Bug5修复：按发送顺序的pending队列（FIFO，存clientId）
  private pendingClientIds: string[] = []
  // 注册给WS的回调：必须写成箭头函数类字段——终生绑死this=本页面；若换成普通方法会丢this
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  // 页面出现：拿入栈参数定身份 → 清未读 → 登记WS监听 → 向服务端要50条历史
  aboutToAppear(): void {
    let params = this.pageStack.getParamByName('ChatPage')[0] as Conversation
    if (params !== undefined && params !== null) {
      this.conversation = params
      this.targetName = params.name
    }
    AppStorage.setOrCreate('currentChatTargetId', this.conversation.targetId)
    try {
      let unreadStr = AppStorage.get<string>('unreadCounts')
      let unreadMap: Record<string, number> = {}
      if (unreadStr !== undefined && unreadStr !== '') {
        unreadMap = JSON.parse(unreadStr) as Record<string, number>
      }
      unreadMap[this.conversation.targetId] = 0
      AppStorage.setOrCreate('unreadCounts', JSON.stringify(unreadMap))
    } catch (_) { /* 忽略JSON解析失败 */ }
    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
    let ws = WebSocketManager.getInstance()
    if (this.conversation.type === 'private') {
      let histData: Record<string, Object> = {
        'type': 'private',
        'targetId': this.conversation.targetId,
        'count': 50
      }
      let histMsg: Record<string, Object> = {
        'type': 'history_request',
        'data': histData
      }
      ws.send(JSON.stringify(histMsg))
    } else {
      let histData: Record<string, Object> = {
        'type': 'group',
        'targetId': this.conversation.targetId,
        'count': 50
      }
      let histMsg: Record<string, Object> = {
        'type': 'history_request',
        'data': histData
      }
      ws.send(JSON.stringify(histMsg))
    }
  }

  // 页面消失：清"正在看的会话"标记 + 撤销WS监听（死页面不能再收消息）
  aboutToDisappear(): void {
    AppStorage.setOrCreate('currentChatTargetId', '')
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  // Bug5：按本地临时ID找回乐观插入的那条消息（返回下标），找不到返回-1
  private findMessageIndexByClientId(clientId: string): number {
    // 从头逐条扫描消息列表
    for (let i = 0; i < this.messages.length; i++) {
      let item = this.messages[i]
      // 三道门全过才算"就是这条"：
      //  ① instanceof TextMessage——先确认它是文字消息（SystemMessage没有clientId字段，挡掉）
      //  ② clientId !== undefined——带过临时ID的才算（服务端下发的历史消息从没打过ID，挡掉）
      //  ③ item.clientId === clientId——ID对上（真正匹配）
      if (item instanceof TextMessage && item.clientId !== undefined && item.clientId === clientId) {
        return i // 命中：返回它的下标
      }
    }
    return -1 // 一圈没找到
  }

  // Bug5（失败路）：服务端报错(400/403/404/500)时调用——把"没发出去的假消息"撤下桌
  private rollbackOldestPending(): void {
    // 队列空 = 没有待确认的消息（比如重复推送的error），没活干
    if (this.pendingClientIds.length <= 0) {
      return
    }
    // shift()：把队头弹出来 = 最早发出的那条pending的ID（FIFO：先发的先被处理）
    let oldestClientId = this.pendingClientIds.shift() as string
    // 拿ID去消息列表找回那条假消息的下标（找不到返回-1）
    let idx = this.findMessageIndexByClientId(oldestClientId)
    // 找到才动手；-1说明已被回滚过，跳过
    if (idx >= 0) {
      // 造个空数组，把"除了idx之外"的消息全部重新装一遍 = 把idx那条挤掉
      let newList: ChatMessage[] = []
      for (let j = 0; j < this.messages.length; j++) {
        if (j !== idx) newList.push(this.messages[j])
      }
      // 整体替换@State：只改newList这个局部变量框架看不见，
      // 换回this.messages才会触发列表刷新——那条假消息从此消失，用户不会误以为发成功了
      this.messages = newList
    }
  }

  // Bug5（成功路）：收到*_sent时调用——把本地假时间换成服务端真实时间，并销掉pending标记
  private confirmOldestPending(serverTimestamp: string): void {
    // 队列空 = 没有待确认的，直接走
    if (this.pendingClientIds.length <= 0) {
      return
    }
    // 取队头=最早发出还没确认的那条ID；shift同时把它弹出队列（确认一次，销一次账）
    let oldestClientId = this.pendingClientIds.shift() as string
    // 按ID找到那条乐观插入消息的下标
    let idx = this.findMessageIndexByClientId(oldestClientId)
    // -1 = 找不到（已回滚/已确认过），无事可做
    if (idx < 0) return
    // 抓出旧消息——重建时从它身上抄content/sender等字段
    let old = this.messages[idx]
    // 复制一份数组：不能直接改old的属性（V1原地改对象属性UI不刷新），要走"改副本+整体换"
    let newList: ChatMessage[] = [...this.messages]
    // 重建时必须保持原类：私聊消息降级成普通消息会丢'[私聊] '前缀
    // 为什么new而不是 old.timestamp=xxx：①原地改属性不刷新 ②按原类new回去才保住行为
    if (old instanceof GroupPrivateMessage) {
      // 原来是群内私信→还按群内私信new：内容/sender全抄旧的，只有时间换成服务端真实时间
      // 注意没传clientId → 新对象clientId=undefined = "已确认完毕，不再需要按ID找我"
      newList[idx] = new GroupPrivateMessage(old.content, serverTimestamp, old.isMine, old.senderId, old.senderUsername, old.senderAvatar)
    } else if (old instanceof TextMessage) {
      // 普通文字消息→按普通消息new回去，同样只换时间、销ID
      newList[idx] = new TextMessage(old.content, serverTimestamp, old.isMine, old.senderId, old.senderUsername, old.senderAvatar)
    }
    // 整体替换@State → UI刷新：列表上那条消息的时间从"本地假时间"变成服务端真实时间
    this.messages = newList
  }

  // WS消息总入口：按type分发（互斥，各分支处理完就return）
  //   history_response → 工厂批量造历史、整体重挂列表
  //   error(400/403/404/500) → 按FIFO回滚最早pending
  //   group_dissolved / group_self_kicked → 群没了/被踢，退页
  //   private_chat_sent / group_*_sent → 成功换真实时间 / 失败回滚
  //   private_chat / group_chat / group_private → 判相关性后插入【Step2待接线】
  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    if (msgType === 'history_response') {
      let msgData = msg['data'] as Record<string, Object>
      let historyArr = msgData['messages'] as Record<string, Object>[]
      let userId = AppStorage.get<string>('userId') ?? ''
      let list: ChatMessage[] = []
      for (let i = 0; i < historyArr.length; i++) {
        let msgItemType = historyArr[i]['type'] as string
        let isMine = historyArr[i]['senderId'] === userId
        let m = MessageFactory.create(msgItemType, historyArr[i], isMine)
        if (m === null) {
          m = new TextMessage(
            historyArr[i]['content'] as string,
            historyArr[i]['timestamp'] as string,
            isMine,
            historyArr[i]['senderId'] as string,
            historyArr[i]['senderUsername'] as string,
            historyArr[i]['senderAvatar'] as string
          )
        }
        list.push(m)
      }
      this.messages = list
      setTimeout(() => {
        this.scrollToBottom()
      }, 100)
      return
    }

    // 处理发送失败（后端返回 type:error）
    if (msgType === 'error') {
      let errData = msg['data'] as Record<string, Object>
      let code = errData['code'] as number
      if (code === 400 || code === 403 || code === 404 || code === 500) {
        // Bug5修复：按FIFO回滚最早pending的本地消息（不再误删最后一条isMine）
        this.rollbackOldestPending()
      }
      return
    }

    if (msgType === 'group_dissolved' && this.conversation.type === 'group') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.conversation.targetId) {
        this.pageStack.pop()
      }
      return
    }

    if (msgType === 'group_self_kicked' && this.conversation.type === 'group') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.conversation.targetId) {
        this.pageStack.pop()
      }
      return
    }

    // 处理发送确认：用服务端返回的真实 timestamp 替换本地乐观插入的临时值
    if (msgType === 'private_chat_sent' && this.conversation.type === 'private') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['success'] === false) {
        this.rollbackOldestPending()
      } else {
        let serverTime = msgData['timestamp'] as string
        if (serverTime !== undefined && serverTime !== '') {
          this.confirmOldestPending(serverTime)
        }
      }
      return
    }
    if ((msgType === 'group_chat_sent' || msgType === 'group_private_sent') && this.conversation.type === 'group') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['success'] === false) {
        this.rollbackOldestPending()
      } else {
        let serverTime = msgData['timestamp'] as string
        if (serverTime !== undefined && serverTime !== '') {
          this.confirmOldestPending(serverTime)
        }
      }
      return
    }

    let relevant = false
    let senderId = ''
    let senderUsername = ''
    let senderAvatar = ''
    let content = ''
    let timestamp = ''

    if (msgType === 'private_chat' && this.conversation.type === 'private') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['senderId'] === this.conversation.targetId) {
        relevant = true
        senderId = msgData['senderId'] as string
        senderUsername = msgData['senderUsername'] as string
        senderAvatar = msgData['senderAvatar'] as string
        content = msgData['content'] as string
        timestamp = msgData['timestamp'] as string
      }
    } else if ((msgType === 'group_chat' || msgType === 'group_private') && this.conversation.type === 'group') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.conversation.targetId) {
        let userId = AppStorage.get<string>('userId') ?? ''
        if (msgData['senderId'] === userId) {
          return
        }
        relevant = true
        senderId = msgData['senderId'] as string
        senderUsername = msgData['senderUsername'] as string
        senderAvatar = msgData['senderAvatar'] as string
        content = msgData['content'] as string
        timestamp = msgData['timestamp'] as string
      }
    }

    if (relevant) {
      let localData: Record<string, Object> = {
        'content': content,
        'timestamp': timestamp,
        'senderId': senderId,
        'senderUsername': senderUsername,
        'senderAvatar': senderAvatar
      }
      let m = MessageFactory.create(msgType, localData, false)
      if (m === null) {
        m = new TextMessage(content, timestamp, false, senderId, senderUsername, senderAvatar)
      }
      this.messages.push(m)
      setTimeout(() => {
        this.scrollToBottom()
      }, 50)
    }
  }

  // 滚动到列表底部（历史加载完 / 新消息到达后调）
  private scrollToBottom(): void {
    if (this.messages.length > 0) {
      this.scroller.scrollToIndex(this.messages.length - 1, false, ScrollAlign.END)
    }
  }

  // 发送主流程：校验非空 → 三分支构造ws消息(私聊/群内私信/群聊) → 本地乐观插入 → 清输入框
  // Bug5：本地插的这条带clientId进pending队列，等服务端 *_sent 来确认、或 error 来撤销
  sendMessage(): void {
    if (this.inputText.trim() === '') {
      return
    }
    let ws = WebSocketManager.getInstance()
    let userId = AppStorage.get<string>('userId') ?? ''
    let username = AppStorage.get<string>('username') ?? ''
    let avatar = AppStorage.get<string>('avatar') ?? ''

    let clientId = simpleClientId()
    let isGroupPrivate = this.conversation.type === 'group' && this.privateTarget !== null
    let displayContent: string = this.inputText
    let outType: string

    if (this.conversation.type === 'private') {
      let innerData: Record<string, Object> = {
        'targetUserId': this.conversation.targetId,
        'content': this.inputText
      }
      let sendMsg: Record<string, Object> = {
        'type': 'private_chat',
        'data': innerData
      }
      ws.send(JSON.stringify(sendMsg))
      outType = 'private_chat'
    } else if (isGroupPrivate) {
      // Bug11：群内私信（group_private）
      let target = this.privateTarget as PrivateTarget
      let innerData: Record<string, Object> = {
        'groupId': this.conversation.targetId,
        'targetUserId': target.userId,
        'content': this.inputText
      }
      let sendMsg: Record<string, Object> = {
        'type': 'group_private',
        'data': innerData
      }
      ws.send(JSON.stringify(sendMsg))
      outType = 'group_private'
    } else {
      let innerData: Record<string, Object> = {
        'groupId': this.conversation.targetId,
        'content': this.inputText
      }
      let sendMsg: Record<string, Object> = {
        'type': 'group_chat',
        'data': innerData
      }
      ws.send(JSON.stringify(sendMsg))
      outType = 'group_chat'
    }

    // 本地立即显示自己发的消息（带clientId标记为"待确认"）
    this.pendingClientIds.push(clientId)
    let localData: Record<string, Object> = {
      'content': displayContent,
      'timestamp': new Date().toLocaleTimeString(),
      'senderId': userId,
      'senderUsername': username,
      'senderAvatar': avatar
    }
    let m = MessageFactory.create(outType, localData, true, clientId)
    if (m === null){
      m = new TextMessage(displayContent, new Date().toLocaleTimeString(), true, userId, username, avatar, clientId)
    }
    this.messages.push(m)
    this.inputText = ''
    // Bug11：发完群内私信后自动退出"私信模式"（用户要再次点头像才能继续发私信给同一个人——防止不小心群消息当私发出去）
    if (isGroupPrivate) {
      this.privateTarget = null
    }
    setTimeout(() => {
      this.scrollToBottom()
    }, 50)
  }

  // Bug11：取消私信模式
  private cancelPrivateTarget(): void {
    this.privateTarget = null
  }

  // Bug11：设置私信目标（点击对方头像/昵称时触发）
  private setPrivateTarget(userId: string, username: string, avatar: string): void {
    let myUserId = AppStorage.get<string>('userId') ?? ''
    if (userId === myUserId) return
    let safeName = username && username.length > 0 ? username : userId
    this.privateTarget = {
      userId: userId,
      username: safeName,
      avatar: avatar
    }
  }

  // 格式化时间戳：ISO字符串 -> HH:mm
  // 注：当前build()没有调用它（预留工具，别找调用点找不到以为是死代码）
  private formatTime(timestamp: string): string {
    if (timestamp.indexOf('T') >= 0) {
      let date = new Date(timestamp)
      return date.toLocaleTimeString()
    }
    return timestamp
  }

  // UI骨架：标题栏 → 私信横幅(条件显示) → 消息列表 → 底部输入栏
  build() {
    NavDestination() {
      Column() {
        // 自定义标题栏
        Row() {
          Text('<')
            .fontSize(24)
            .fontColor('#333333')
            .padding({ left: 12, right: 8 })
            .onClick(() => {
              this.pageStack.pop()
            })
          Text(this.targetName)
            .fontSize(18)
            .fontColor('#333333')
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
          if (this.conversation.type === 'group') {
            Text('⋯')
              .fontSize(24)
              .fontColor('#333333')
              .padding({ left: 8, right: 12 })
              .onClick(() => {
                let c = new Conversation()
                c.type = this.conversation.type
                c.targetId = this.conversation.targetId
                c.name = this.conversation.name
                c.avatar = this.conversation.avatar
                this.pageStack.pushPath({ name: 'GroupDetailPage', param: c })
              })
          } else {
            Text('')
              .width(44)
          }
        }
        .width('100%')
        .height(56)
        .backgroundColor(Color.White)
        .alignItems(VerticalAlign.Center)

        // Bug11：私信模式横幅（输入栏上方提示用户正在给XX发私信）
        if (this.conversation.type === 'group' && this.privateTarget !== null) {
          Row() {
            Image($r(`app.media.${this.privateTarget!.avatar && this.privateTarget!.avatar.length > 0 ? this.privateTarget!.avatar : 'youling'}`))
              .width(20)
              .height(20)
              .borderRadius(10)
              .margin({ right: 6 })
            Text(`正在给「${this.privateTarget!.username}」发群内私信`)
              .fontSize(12)
              .fontColor('#555555')
              .layoutWeight(1)
            Text('取消')
              .fontSize(12)
              .fontColor('#576B95')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .onClick(() => {
                this.cancelPrivateTarget()
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor('#FFF8E1')
        }

        // 消息列表：ForEach按key区分每条气泡（key要含clientId，确认/回滚后重渲染才不错位）
        List({ space: 12, scroller: this.scroller }) {
          ForEach(this.messages, (item: ChatMessage, index: number) => {
            ListItem() {
              if(item instanceof SystemMessage) {
                Row(){
                  Text(item.displayText())
                    .fontSize(12)
                    .fontColor('#999999')
                    .padding({left: 12, right: 12, top: 4, bottom: 4})
                    .backgroundColor('#E5E5E5')
                    .borderRadius(4)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({left: 16, right: 16})
              } else if (item instanceof TextMessage && item.isMine) {
                // 我发的 → 右气泡（绿底白字）+ 我的头像在右
                Row() {
                  Blank().layoutWeight(1)
                  Column() {
                    Text(item.displayText())
                      .fontSize(16)
                      .fontColor(Color.White)
                      .wordBreak(WordBreak.BREAK_ALL)
                  }
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .constraintSize({ maxWidth: '65%' })
                  .backgroundColor('#95EC69')
                  .borderRadius({ topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16 })
                  Image($r(`app.media.${item.senderAvatar && item.senderAvatar.length > 0 ? item.senderAvatar : 'youling'}`))
                    .width(40)
                    .height(40)
                    .borderRadius(20)
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
                .alignItems(VerticalAlign.Top)
              } else if(item instanceof TextMessage){
                // 对方发的 → 左气泡（白底黑字）+ 左侧头像昵称（可点，Bug11进私信模式）
                // 【Step2待接线】改为 instanceof 分支：SystemMessage灰条 / TextMessage气泡，
                // 文字不再用 item.content，改用 item.displayText()（私聊前缀靠覆写自动带）
                Row() {
                  // Bug11：对方头像可点击（群聊才生效）设置私信目标
                  Image($r(`app.media.${item.senderAvatar && item.senderAvatar.length > 0 ? item.senderAvatar : 'youling'}`))
                    .width(40)
                    .height(40)
                    .borderRadius(20)
                    .margin({ right: 8 })
                    .onClick(() => {
                      if (this.conversation.type === 'group') {
                        this.setPrivateTarget(item.senderId, item.senderUsername, item.senderAvatar)
                      }
                    })
                  Column() {
                    if (this.conversation.type === 'group') {
                      // Bug11：群聊昵称也能点击设置私信对象
                      Text(item.senderUsername)
                        .fontSize(12)
                        .fontColor('#888888')
                        .margin({ bottom: 4 })
                        .onClick(() => {
                          this.setPrivateTarget(item.senderId, item.senderUsername, item.senderAvatar)
                        })
                    }
                    Text(item.displayText())
                      .fontSize(16)
                      .fontColor('#333333')
                      .wordBreak(WordBreak.BREAK_ALL)
                  }
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .constraintSize({ maxWidth: '65%' })
                  .backgroundColor(Color.White)
                  .borderRadius({ topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16 })
                  .alignItems(HorizontalAlign.Start)

                  Blank().layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
                .alignItems(VerticalAlign.Top)
              }
            }
          }, (item: ChatMessage, index: number) => `${index}_${item.timestamp}_${item instanceof TextMessage && item.clientId !== undefined ? item.clientId : 'x'}`)
        }
        .width('100%')
        .layoutWeight(1)
        .alignListItem(ListItemAlign.Start)
        .backgroundColor('#EDEDED')
        .padding({ top: 12, bottom: 8 })

        
        Row() {
          TextInput({
            placeholder: (this.conversation.type === 'group' && this.privateTarget !== null)
              ? `给 ${this.privateTarget!.username} 发私信...` : '输入消息...',
            text: this.inputText
          })
            .layoutWeight(1)
            .height(40)
            .backgroundColor(Color.White)
            .borderRadius(20)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.inputText = value
            })
          Button('发送')
            .height(40)
            .width(64)
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor((this.conversation.type === 'group' && this.privateTarget !== null) ? '#576B95' : '#07C160')
            .borderRadius(20)
            .margin({ left: 8 })
            .onClick(() => {
              this.sendMessage()
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#F6F6F6')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
  }
}

@Builder
export function ChatPageBuilder() {
  ChatPage()
}
