// ============================================================
// Message.ets —— 消息类型 + 工厂（工厂模式实战落地）
// ------------------------------------------------------------
// 病根（改造前）："一条消息怎么显示"散在 ChatPage 手拼——'[私聊] '前缀拼了3处，
// 想加一种新消息（系统灰条）连放的地方都没有。
// 现在：显示知识搬回消息自己身上，ChatPage 只问每条消息一句话：
//        "你显示出来是啥？" → item.displayText()
//
// 类型地图：
//   ChatMessage                 底座：content + timestamp + displayText()
//   ├── TextMessage             人发的文字消息：sender三件套 + isMine + clientId
//   │   └── GroupPrivateMessage  群内私信：只覆写displayText()加'[私聊] '前缀
//   └── SystemMessage           系统灰条：不是人发的，直接站底座、不经过TextMessage
//   MessageFactory              对照表："type字符串 → new 谁"，造对象的知识只存这一份
//
// 两根柱子：声明类型=柱①（列表只认ChatMessage），实际new谁=柱②
//   displayText()跑谁的版本由柱②决定——渲染统一、行为各异，就是多态。
// ============================================================

// 底座：所有消息的公共部分，渲染列表只认这个类型
export class ChatMessage{
  content: string    // 消息正文（原始内容）
  timestamp: string; // 时间戳（服务端ISO串，或本地 toLocaleTimeString()）
  constructor(content: string, timestamp: string) {
    this.content = content
    this.timestamp = timestamp
  }
  // 渲染的统一入口："显示出来是啥？"——基类返回原文，子类覆写换版本
  displayText():string{
    return this.content
  }
}

// 人发的文字消息 = 在底座上多出"谁发的 / 我发的 / 待确认"这些字段
export class TextMessage extends ChatMessage{
  isMine: boolean        // 是不是我发的（决定渲染右气泡还是左气泡）
  senderId: string       // 发送者userId（左气泡点对方头像→拿它设群内私信对象）
  senderUsername: string // 发送者昵称（群聊气泡上方显示、可点击）
  senderAvatar: string   // 发送者头像资源名
  clientId?: string      // 本地临时ID：乐观插入打的"待确认"标记，服务端确认/回滚时按它找回这条
  // 构造：子类第一行必须 super(...)——父类那半先造（孪生兄弟）
  constructor(content: string, timestamp: string,isMine: boolean, senderId: string, senderUsername: string, senderAvatar: string,clientId?: string) {
    super(content, timestamp)
    this.isMine = isMine
    this.senderId = senderId
    this.senderUsername = senderUsername
    this.senderAvatar = senderAvatar
    this.clientId = clientId // 参数进了门就要登记——不登记，Bug5按ID找人时永远找不到
  }
}

// 群内私信 = 一种TextMessage（sender字段全白拿，一个都不用声明）
// 唯一区别：显示时前面加'[私聊] '——所以只覆写displayText这一个方法
export class GroupPrivateMessage extends TextMessage{
  // 覆写：同名方法换自己的版本（柱②是GroupPrivateMessage时跑这里）
  displayText(): string {
    return '[私聊] ' + this.content
  }
}

// 系统消息（"XX退出了群聊"这类灰条）：
// 是ChatMessage（有内容、有时间、要显示），但不是TextMessage（没有人发、没有头像、不分左右）
// 直接站底座 = 不被迫继承isMine/sender三件套这些没意义的字段（is-a只继承"真的是"的那条线）
export class SystemMessage extends ChatMessage {
  // 只收content——时间自己生成（系统消息没有"发送时刻"，就是看到它的时刻）
  constructor(content: string) {
    super(content, new Date().toLocaleTimeString())
  }
}

// 工厂：'type字符串 → new 哪个类'的对照表收在一处
// 主心骨：造对象的知识只存一份 + 使用方只认父类（新增类型只动这里，不动ChatPage）
// 契约：未知type返回null——调用方必须兜底（ChatPage用TextMessage兜底）
export class MessageFactory {
  // data备齐五个字段即可：content/timestamp/senderId/senderUsername/senderAvatar（服务端下发的data原样）
  // isMine由调用方告诉工厂"这条是不是我发的"；clientId可选——只有本地乐观插入的才有
  static create(type: string, data: Record<string, Object>, isMine: boolean, clientId?: string): ChatMessage | null {
    if (type === 'private_chat' || type === 'group_chat') {
      return new TextMessage(
        data['content'] as string,
        data['timestamp'] as string,
        isMine,
        data['senderId'] as string,
        data['senderUsername'] as string,
        data['senderAvatar'] as string,
        clientId
      )
    }
    if (type === 'group_private') {
      return new GroupPrivateMessage(
        data['content'] as string,
        data['timestamp'] as string,
        isMine,
        data['senderId'] as string,
        data['senderUsername'] as string,
        data['senderAvatar'] as string,
        clientId
      )
    }
    return null
  }

  // 造一条系统消息（灰条）
  static createSystem(content: string): SystemMessage {
    return new SystemMessage(content)
  }
}
