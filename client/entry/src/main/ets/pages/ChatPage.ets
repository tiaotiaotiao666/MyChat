import WebSocketManager from '../model/WebSocketManager'
import { Conversation } from '../model/Conversation'

// 单条聊天消息的数据结构
interface ChatMessage {
  isMine: boolean
  senderId: string
  senderUsername: string
  senderAvatar: string
  content: string
  timestamp: string
  clientId?: string // Bug5修复：前端乐观插入时的唯一ID，用于匹配_sent/error做FIFO回滚
}

// Bug11：群内私信的目标对象
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
  @Consume('pageStack') pageStack: NavPathStack
  @State messages: ChatMessage[] = []
  @State inputText: string = ''
  @State targetName: string = ''
  // Bug11：群聊模式下的私信目标（不为空表示当前正在给XX发群内私信）
  @State privateTarget: PrivateTarget | null = null
  private conversation: Conversation = new Conversation()
  private scroller: Scroller = new Scroller()
  // Bug5修复：按发送顺序的pending队列（FIFO，存clientId）
  private pendingClientIds: string[] = []
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

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

  aboutToDisappear(): void {
    AppStorage.setOrCreate('currentChatTargetId', '')
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  // Bug5：根据clientId找到该条消息在this.messages中的下标；找不到返回-1
  private findMessageIndexByClientId(clientId: string): number {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].clientId !== undefined && this.messages[i].clientId === clientId) {
        return i
      }
    }
    return -1
  }

  // Bug5：按FIFO取最早一条pending的clientId，然后从messages里移除对应那一条
  private rollbackOldestPending(): void {
    if (this.pendingClientIds.length <= 0) {
      return
    }
    let oldestClientId = this.pendingClientIds.shift() as string
    let idx = this.findMessageIndexByClientId(oldestClientId)
    if (idx >= 0) {
      let newList: ChatMessage[] = []
      for (let j = 0; j < this.messages.length; j++) {
        if (j !== idx) newList.push(this.messages[j])
      }
      this.messages = newList
    }
  }

  // Bug5：_sent成功时，按FIFO取最早pending，把对应消息的timestamp替换为服务端真实时间（并清掉clientId标记已确认）
  private confirmOldestPending(serverTimestamp: string): void {
    if (this.pendingClientIds.length <= 0) {
      return
    }
    let oldestClientId = this.pendingClientIds.shift() as string
    let idx = this.findMessageIndexByClientId(oldestClientId)
    if (idx < 0) return
    let newList: ChatMessage[] = [...this.messages]
    newList[idx] = {
      isMine: newList[idx].isMine,
      senderId: newList[idx].senderId,
      senderUsername: newList[idx].senderUsername,
      senderAvatar: newList[idx].senderAvatar,
      content: newList[idx].content,
      timestamp: serverTimestamp
      // 不保留clientId：确认后不再需要
    }
    this.messages = newList
  }

  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    if (msgType === 'history_response') {
      let msgData = msg['data'] as Record<string, Object>
      let historyArr = msgData['messages'] as Record<string, Object>[]
      let userId = AppStorage.get<string>('userId') ?? ''
      let list: ChatMessage[] = []
      for (let i = 0; i < historyArr.length; i++) {
        let rawContent = historyArr[i]['content'] as string
        let msgItemType = historyArr[i]['type'] as string
        let content = rawContent
        if (msgItemType === 'group_private') {
          content = '[私聊] ' + rawContent
        }
        let m: ChatMessage = {
          isMine: historyArr[i]['senderId'] === userId,
          senderId: historyArr[i]['senderId'] as string,
          senderUsername: historyArr[i]['senderUsername'] as string,
          senderAvatar: historyArr[i]['senderAvatar'] as string,
          content: content,
          timestamp: historyArr[i]['timestamp'] as string
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
        if (msgType === 'group_private') {
          content = '[私聊] ' + content
        }
      }
    }

    if (relevant) {
      let m: ChatMessage = {
        isMine: false,
        senderId: senderId,
        senderUsername: senderUsername,
        senderAvatar: senderAvatar,
        content: content,
        timestamp: timestamp
      }
      this.messages.push(m)
      setTimeout(() => {
        this.scrollToBottom()
      }, 50)
    }
  }

  // 滚动到列表底部
  private scrollToBottom(): void {
    if (this.messages.length > 0) {
      this.scroller.scrollToIndex(this.messages.length - 1, false, ScrollAlign.END)
    }
  }

  sendMessage(): void {
    if (this.inputText.trim() === '') {
      return
    }
    let ws = WebSocketManager.getInstance()
    let userId = AppStorage.get<string>('userId') ?? ''
    let username = AppStorage.get<string>('username') ?? ''
    let avatar = AppStorage.get<string>('avatar') ?? ''

    // Bug5：每条乐观插入的本地消息都带一个唯一clientId，并push到pending队列（FIFO）
    let clientId = simpleClientId()
    let isGroupPrivate = this.conversation.type === 'group' && this.privateTarget !== null
    let displayContent: string

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
      displayContent = this.inputText
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
      displayContent = '[私聊] ' + this.inputText
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
      displayContent = this.inputText
    }

    // 本地立即显示自己发的消息（带clientId标记为"待确认"）
    this.pendingClientIds.push(clientId)
    let m: ChatMessage = {
      isMine: true,
      senderId: userId,
      senderUsername: username,
      senderAvatar: avatar,
      content: displayContent,
      timestamp: new Date().toLocaleTimeString(),
      clientId: clientId
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
  private formatTime(timestamp: string): string {
    if (timestamp.indexOf('T') >= 0) {
      let date = new Date(timestamp)
      return date.toLocaleTimeString()
    }
    return timestamp
  }

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

        List({ space: 12, scroller: this.scroller }) {
          ForEach(this.messages, (item: ChatMessage, index: number) => {
            ListItem() {
              if (item.isMine) {
                Row() {
                  Blank().layoutWeight(1)
                  Column() {
                    Text(item.content)
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
              } else {
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
                    Text(item.content)
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
          }, (item: ChatMessage, index: number) => `${index}_${item.timestamp}_${item.clientId ?? 'x'}`)
        }
        .width('100%')
        .layoutWeight(1)
        .alignListItem(ListItemAlign.Start)
        .backgroundColor('#EDEDED')
        .padding({ top: 12, bottom: 8 })

        // 底部输入栏（Bug11：如果处于私信模式，placeholder提示给XX发私信）
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
