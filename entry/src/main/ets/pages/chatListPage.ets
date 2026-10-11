// ============================================================
// ChatListPage —— 主页（微信风格四Tab：消息 / 好友 / 通知 / 我的）
// ------------------------------------------------------------
// 职责：① 会话列表（点行进ChatPage）② 好友/群组管理 ③ 申请与系统通知 ④ 个人信息/退出
// 数据源：AppStorage（login_response下发的好友/群/未读都持久化在这）+ WS实时推送
// 状态同步铁三角（改了必须写回，否则下次登录丢失）：
//   未读 → syncUnreadCountsToAppStorage  |  最后一条 → syncLastMessageToAppStorage
//   列表刷新 → refreshConversations()（@State数组原地改属性不刷新，必须clone+version+1整体替换）
// WS消息全部收进 onMessage 一个大分发器（好友/群/申请/确认/实时消息）
// ============================================================
import { Conversation } from '../model/Conversation'
import WebSocketManager from '../model/WebSocketManager'
import { preferences } from '@kit.ArkData'

// 好友数据结构
interface FriendInfo {
  userId: string
  username: string
  avatar: string
}

// 好友请求（加未读标记，用于通知Tab单条红点）
interface FriendRequestItem {
  fromUserId: string
  fromUsername: string
  fromAvatar: string
  unread: boolean
}

// 入群请求（加未读标记）
interface GroupRequestItem {
  groupId: string
  groupName: string
  fromUserId: string
  fromUsername: string
  fromAvatar: string
  unread: boolean
}

// 我的群组（Tab2好友页的群组分区用）
interface GroupInfo {
  groupId: string
  groupName: string
  owner: string
  ownerAvatar: string
}

// 系统通知条目（被删好友/被踢/群解散这类，带未读小红点，Tab3展示）
interface SystemNotify {
  id: string
  type: string
  content: string
  timestamp: string
  unread: boolean
}

@Component
struct ChatListPage {
  @Consume('pageStack') pageStack: NavPathStack // 跳转栈（Index @Provide的）
  @State conversations: Conversation[] = [] // Tab1：会话列表（消息行，核心数据）
  @State friends: FriendInfo[] = [] // Tab2：好友列表
  @State myGroups: GroupInfo[] = [] // Tab2：我的群组
  @State friendRequests: FriendRequestItem[] = [] // Tab3：好友申请（带单条未读）
  @State groupRequests: GroupRequestItem[] = [] // Tab3：入群申请（带单条未读）
  @State systemNotifies: SystemNotify[] = [] // Tab3：系统通知（被删/被踢/解散）
  @State userId: string = '' // 我的账号（login后从AppStorage读，Tab4展示）
  @State username: string = ''
  @State avatar: string = ''
  // 安全加固：被顶号信号——WebSocketManager拦截到kicked消息时写AppStorage.kickReason，
  // 这里用@Watch观察它。被顶号可能发生在任何页面，主页面负责统一善后
  @StorageProp('kickReason') @Watch('onKicked') kickReason: string = ''
  @State showFriendMenu: boolean = false // Tab2右上"+"弹出菜单开合
  @State currentTab: number = 0 // 当前Tab下标（0消息/1好友/2通知/3我的）
  @State currentChatTargetId: string = '' // 当前正在看的聊天targetId，用于屏蔽未读
  @State showSettingsTip: boolean = false // Tab4设置提示弹窗开合
  @State tipText: string = '' // 顶部Toast文字（showTip()触发，空=不显示）
  private tipTimerId: number = -1 // Toast自动消失的定时器ID
  // 注册给WS的回调：箭头类字段终生绑this=本页面（同ChatPage，换成普通方法会丢this）
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  // ========== 通用浮层 Toast（ArkTS 不依赖系统 promptAction，任何 API 版本都能用） ==========
  private showTip(text: string, durationMs: number = 3000): void {
    if (this.tipTimerId >= 0) {
      clearTimeout(this.tipTimerId)
      this.tipTimerId = -1
    }
    this.tipText = text
    this.tipTimerId = setTimeout(() => {
      this.tipText = ''
      this.tipTimerId = -1
    }, durationMs) as number
  }

  // ========== 工具：未读数量汇总（Tab红点用） ==========

  // 消息Tab总未读：所有会话unreadCount之和（>99显示99+）
  private getMsgTabUnread(): number {
    let total = 0
    for (let i = 0; i < this.conversations.length; i++) {
      total += this.conversations[i].unreadCount > 0 ? this.conversations[i].unreadCount : 0
    }
    return total > 0 ? total : 0
  }

  // 通知Tab总未读：friendRequests.unread + groupRequests.unread 之和
  private getNotifyTabUnread(): number {
    let total = 0
    for (let i = 0; i < this.friendRequests.length; i++) {
      if (this.friendRequests[i].unread) total += 1
    }
    for (let i = 0; i < this.groupRequests.length; i++) {
      if (this.groupRequests[i].unread) total += 1
    }
    for (let i = 0; i < this.systemNotifies.length; i++) {
      if (this.systemNotifies[i].unread) total += 1
    }
    return total
  }

  // 切到通知Tab时，把所有friendRequests/groupRequests的未读标记清零
  private clearNotifyTabUnread(): void {
    let changed = false
    for (let i = 0; i < this.friendRequests.length; i++) {
      if (this.friendRequests[i].unread) {
        this.friendRequests[i].unread = false
        changed = true
      }
    }
    for (let i = 0; i < this.groupRequests.length; i++) {
      if (this.groupRequests[i].unread) {
        this.groupRequests[i].unread = false
        changed = true
      }
    }
    for (let i = 0; i < this.systemNotifies.length; i++) {
      if (this.systemNotifies[i].unread) {
        this.systemNotifies[i].unread = false
        changed = true
      }
    }
    if (changed) {
      this.friendRequests = [...this.friendRequests]
      this.groupRequests = [...this.groupRequests]
      this.systemNotifies = [...this.systemNotifies]
    }
  }

  // ========== 底部Tab自定义组件（文字 + 右上角红点数量） ==========
  @Builder TabWithBadge(text: string, tabIndex: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(text)
          .fontSize(14)
          .fontColor(this.currentTab === tabIndex ? '#07C160' : '#888888')
          .fontWeight(this.currentTab === tabIndex ? FontWeight.Medium : FontWeight.Normal)
          .margin({ top: 6, bottom: 6 })
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      if (tabIndex === 0 && this.getMsgTabUnread() > 0) {
        Text(this.getMsgTabUnread() > 99 ? '99+' : this.getMsgTabUnread().toString())
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor('#F04848')
          .borderRadius(8)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .constraintSize({ minWidth: 16, minHeight: 16 })
          .textAlign(TextAlign.Center)
          .margin({ top: 2, right: 10 })
          .fontWeight(FontWeight.Medium)
          .zIndex(99)
      }
      if (tabIndex === 2 && this.getNotifyTabUnread() > 0) {
        Text(this.getNotifyTabUnread() > 99 ? '99+' : this.getNotifyTabUnread().toString())
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor('#F04848')
          .borderRadius(8)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .constraintSize({ minWidth: 16, minHeight: 16 })
          .textAlign(TextAlign.Center)
          .margin({ top: 2, right: 10 })
          .fontWeight(FontWeight.Medium)
          .zIndex(99)
      }
    }
    .width(88)
    .height(44)
  }

  // 页面出现：从AppStorage恢复好友/群/未读/申请（JSON字符串→对象）→ 登记WS监听
  aboutToAppear(): void {
    // 解析好友列表
    let friendsStr = AppStorage.get<string>('friends')
    if (friendsStr === undefined) {
      friendsStr = '[]'
    }
    let friendsArr = JSON.parse(friendsStr) as Record<string, Object>[]
    let friendList: FriendInfo[] = []
    for (let i = 0; i < friendsArr.length; i++) {
      friendList.push({
        userId: friendsArr[i]['userId'] as string,
        username: friendsArr[i]['username'] as string,
        avatar: friendsArr[i]['avatar'] as string
      })
    }
    this.friends = friendList

    // 解析群组列表并构建会话
    let groupsStr = AppStorage.get<string>('groups')
    if (groupsStr === undefined) {
      groupsStr = '[]'
    }
    let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
    let list: Conversation[] = []
    let groupList: GroupInfo[] = []
    // 群组会话
    for (let i = 0; i < groupsArr.length; i++) {
      groupList.push({
        groupId: groupsArr[i]['groupId'] as string,
        groupName: groupsArr[i]['groupName'] as string,
        owner: groupsArr[i]['owner'] as string,
        ownerAvatar: groupsArr[i]['ownerAvatar'] as string
      })
      let c = new Conversation()
      c.type = 'group'
      c.targetId = groupsArr[i]['groupId'] as string
      c.name = groupsArr[i]['groupName'] as string
      c.avatar = groupsArr[i]['ownerAvatar'] as string
      let lastMsg = groupsArr[i]['lastMessage']
      let lastTime = groupsArr[i]['lastTime']
      if (lastMsg !== undefined && lastMsg !== null && String(lastMsg) !== '') {
        c.lastMessage = String(lastMsg)
        if (lastTime !== undefined && lastTime !== null && String(lastTime) !== '') {
          c.lastTime = this.formatTimestamp(String(lastTime))
        }
      }
      list.push(c)
    }
    // 好友会话
    for (let i = 0; i < friendsArr.length; i++) {
      let c = new Conversation()
      c.type = 'private'
      c.targetId = friendsArr[i]['userId'] as string
      c.name = friendsArr[i]['username'] as string
      c.avatar = friendsArr[i]['avatar'] as string
      let lastMsg = friendsArr[i]['lastMessage']
      let lastTime = friendsArr[i]['lastTime']
      if (lastMsg !== undefined && lastMsg !== null && String(lastMsg) !== '') {
        c.lastMessage = String(lastMsg)
        if (lastTime !== undefined && lastTime !== null && String(lastTime) !== '') {
          c.lastTime = this.formatTimestamp(String(lastTime))
        }
      }
      list.push(c)
    }

    // 恢复未读计数
    let unreadStr = AppStorage.get<string>('unreadCounts')
    if (unreadStr !== undefined && unreadStr !== '') {
      let unreadMap = JSON.parse(unreadStr) as Record<string, number>
      for (let i = 0; i < list.length; i++) {
        let count = unreadMap[list[i].targetId]
        if (count !== undefined && count > 0) {
          list[i].unreadCount = count
        }
      }
    }

    // 排序：有未读→有消息→无消息
    this.conversations = this.sortConversations(list)
    this.myGroups = groupList

    // 恢复好友请求列表（从后端 login_response 返回的 friendRequests）
    let friendReqsStr = AppStorage.get<string>('friendRequests')
    if (friendReqsStr !== undefined && friendReqsStr !== '') {
      try {
        let reqsArr = JSON.parse(friendReqsStr) as Record<string, Object>[]
        let reqList: FriendRequestItem[] = []
        for (let i = 0; i < reqsArr.length; i++) {
          if (reqsArr[i]['status'] === 'pending') {
            reqList.push({
              fromUserId: reqsArr[i]['from'] as string,
              fromUsername: reqsArr[i]['username'] as string,
              fromAvatar: reqsArr[i]['avatar'] as string,
              unread: false
            })
          }
        }
        this.friendRequests = reqList
      } catch (e) {
      }
    }

    // 恢复入群请求列表（从后端 login_response 返回的 groupJoinRequests）
    let groupReqsStr = AppStorage.get<string>('groupJoinRequests')
    if (groupReqsStr !== undefined && groupReqsStr !== '') {
      try {
        let gReqArr = JSON.parse(groupReqsStr) as Record<string, Object>[]
        let gReqList: GroupRequestItem[] = []
        for (let i = 0; i < gReqArr.length; i++) {
          gReqList.push({
            groupId: gReqArr[i]['groupId'] as string,
            groupName: gReqArr[i]['groupName'] as string,
            fromUserId: gReqArr[i]['from'] as string,
            fromUsername: gReqArr[i]['username'] as string,
            fromAvatar: gReqArr[i]['avatar'] as string,
            unread: false
          })
        }
        this.groupRequests = gReqList
      } catch (e) {
      }
    }

    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
    this.userId = AppStorage.get<string>('userId') ?? ''
    this.username = AppStorage.get<string>('username') ?? ''
    this.avatar = AppStorage.get<string>('avatar') ?? ''
  }

  aboutToDisappear(): void {
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  // 从 AppStorage 同步 lastMessage/unreadCounts，解决从子页面返回后数据不一致
  private syncFromAppStorage(): void {
    let unreadStr = AppStorage.get<string>('unreadCounts')
    if (unreadStr !== undefined && unreadStr !== '') {
      try {
        let unreadMap = JSON.parse(unreadStr) as Record<string, number>
        let changed = false
        for (let i = 0; i < this.conversations.length; i++) {
          let targetId = this.conversations[i].targetId
          let count = unreadMap[targetId]
          if (count !== undefined && this.conversations[i].unreadCount !== count) {
            this.conversations[i].unreadCount = count
            changed = true
          }
        }
        if (changed) {
          this.refreshConversations()
        }
      } catch (_) {
      }
    }
  }

  // 把内存中的 unreadCounts 同步写回 AppStorage（解决Bug1/2：下次登录/刷新时红点和数量不丢）
  private syncUnreadCountsToAppStorage(): void {
    let unreadMap: Record<string, number> = {}
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].unreadCount > 0) {
        unreadMap[this.conversations[i].targetId] = this.conversations[i].unreadCount
      }
    }
    AppStorage.setOrCreate('unreadCounts', JSON.stringify(unreadMap))
  }

  // 把某个会话的 lastMessage/lastTime 反向写回 AppStorage.friends 和 AppStorage.groups
  // （解决"最后一条消息不实时显示"：下次 aboutToAppear/onPageShow 能重新读出来，跨页面一致）
  private syncLastMessageToAppStorage(targetId: string, type: string, lastMessage: string, lastTime: string): void {
    if (type === 'private') {
      let friendsStr = AppStorage.get<string>('friends')
      if (friendsStr === undefined || friendsStr === '') return
      try {
        let friendsArr = JSON.parse(friendsStr) as Record<string, string>[]
        for (let i = 0; i < friendsArr.length; i++) {
          if ((friendsArr[i]['userId'] as string) === targetId) {
            friendsArr[i]['lastMessage'] = lastMessage
            friendsArr[i]['lastTime'] = lastTime
            AppStorage.setOrCreate('friends', JSON.stringify(friendsArr))
            return
          }
        }
      } catch (_) { /* JSON解析失败，忽略 */ }
    } else if (type === 'group') {
      let groupsStr = AppStorage.get<string>('groups')
      if (groupsStr === undefined || groupsStr === '') return
      try {
        let groupsArr = JSON.parse(groupsStr) as Record<string, string>[]
        for (let i = 0; i < groupsArr.length; i++) {
          if ((groupsArr[i]['groupId'] as string) === targetId) {
            groupsArr[i]['lastMessage'] = lastMessage
            groupsArr[i]['lastTime'] = lastTime
            AppStorage.setOrCreate('groups', JSON.stringify(groupsArr))
            return
          }
        }
      } catch (_) { /* JSON解析失败，忽略 */ }
    }
  }

  // ============ 时间格式化工具（微信风格：HH:MM，不带秒） ============

  // 把任意Date或毫秒转成"HH:MM"
  private dateToHHMM(date: Date): string {
    let h = date.getHours()
    let m = date.getMinutes()
    let hh = (h < 10 ? '0' : '') + h.toString()
    let mm = (m < 10 ? '0' : '') + m.toString()
    return `${hh}:${mm}`
  }

  // 新消息当前时间：直接用"HH:MM"（微信风格）
  private nowHHMM(): string {
    return this.dateToHHMM(new Date())
  }

  // 格式化ISO时间戳为本地时间（微信风格：当天HH:MM，昨天显示"昨天"，更早显示MM-DD）
  private formatTimestamp(isoStr: string): string {
    if (isoStr === undefined || isoStr === '') {
      return ''
    }
    let d: Date | null = null
    if (isoStr.indexOf('T') >= 0) {
      d = new Date(isoStr)
    } else {
      // 尝试兼容 "HH:MM:SS" / "HH:MM" 这种今天的时间字符串
      let parts = isoStr.split(':')
      if (parts.length >= 2) {
        let now = new Date()
        now.setHours(parseInt(parts[0]), parseInt(parts[1]), parts.length >= 3 ? parseInt(parts[2]) : 0, 0)
        d = now
      }
    }
    if (d === null || isNaN(d.getTime())) {
      // 解析失败就返回原串但最多20字符
      return isoStr.length > 20 ? isoStr.substring(0, 20) : isoStr
    }
    let now = new Date()
    let y0 = now.getFullYear(), m0 = now.getMonth(), day0 = now.getDate()
    let y1 = d.getFullYear(), m1 = d.getMonth(), day1 = d.getDate()
    // 今天
    if (y0 === y1 && m0 === m1 && day0 === day1) {
      return this.dateToHHMM(d)
    }
    // 昨天
    let yesterday = new Date(y0, m0, day0 - 1)
    if (yesterday.getFullYear() === y1 && yesterday.getMonth() === m1 && yesterday.getDate() === day1) {
      return '昨天'
    }
    // 同一年：MM-DD
    if (y0 === y1) {
      let mm = (m1 + 1 < 10 ? '0' : '') + (m1 + 1).toString()
      let dd = (day1 < 10 ? '0' : '') + day1.toString()
      return `${mm}-${dd}`
    }
    // 更早：YYYY-MM-DD
    let yyyy = y1.toString()
    let mm = (m1 + 1 < 10 ? '0' : '') + (m1 + 1).toString()
    let dd = (day1 < 10 ? '0' : '') + day1.toString()
    return `${yyyy}-${mm}-${dd}`
  }

  // 解析会话的lastTime为可比较的数字（越大越新）
  // lastTime可能是ISO字符串（含T）或者toLocaleTimeString（HH:MM:SS），无法直接转Date的按0处理
  private lastTimeToValue(c: Conversation): number {
    let t = c.lastTime
    if (t === undefined || t === '') {
      return 0
    }
    if (t.indexOf('T') >= 0) {
      let d = new Date(t)
      let v = d.getTime()
      return isNaN(v) ? 0 : v
    }
    // HH:MM:SS 或 HH:MM 格式，当天时间直接给它映射成秒数
    let parts = t.split(':')
    if (parts.length >= 2) {
      let h = parseInt(parts[0])
      let m = parseInt(parts[1])
      let s = parts.length >= 3 ? parseInt(parts[2]) : 0
      if (!isNaN(h) && !isNaN(m) && !isNaN(s)) {
        // 加上今日零点，保证跨天排序正确（虽然不是严格的，但比0强）
        let now = new Date()
        now.setHours(h, m, s, 0)
        return now.getTime()
      }
    }
    return 0
  }

  // 按时间戳降序排列（最新的在前），用于桶内排序
  private sortByTimeDesc(arr: Conversation[]): Conversation[] {
    if (arr.length <= 1) {
      return arr
    }
    return arr.sort((a: Conversation, b: Conversation) => {
      let va = this.lastTimeToValue(a)
      let vb = this.lastTimeToValue(b)
      return vb - va
    })
  }

  // 排序：有未读的排最前→有消息的→无消息的；每个桶内部再按lastTime降序（新消息置顶）
  private sortConversations(list: Conversation[]): Conversation[] {
    let withUnread: Conversation[] = []
    let withMsg: Conversation[] = []
    let noMsg: Conversation[] = []
    for (let i = 0; i < list.length; i++) {
      if (list[i].unreadCount > 0) {
        withUnread.push(list[i])
      } else if (list[i].lastMessage !== '') {
        withMsg.push(list[i])
      } else {
        noMsg.push(list[i])
      }
    }
    return this.sortByTimeDesc(withUnread)
      .concat(this.sortByTimeDesc(withMsg))
      .concat(this.sortByTimeDesc(noMsg))
  }

  // 强制刷新会话列表（@State数组内对象属性变化需要整体重新赋值）
  private cloneConversation(c: Conversation): Conversation {
    let nc = new Conversation()
    nc.type = c.type
    nc.targetId = c.targetId
    nc.name = c.name
    nc.avatar = c.avatar
    nc.lastMessage = c.lastMessage
    nc.lastTime = c.lastTime
    nc.unreadCount = c.unreadCount
    nc.version = c.version + 1
    return nc
  }

  private refreshConversations(): void {
    this.conversations = this.sortConversations(this.conversations.map((c: Conversation): Conversation => this.cloneConversation(c)))
  }

  // 强制刷新好友列表
  private refreshFriends(): void {
    this.friends = [...this.friends]
  }

  // 添加群组到myGroups状态
  private addGroupToMyGroups(groupId: string, groupName: string, owner: string, ownerAvatar: string): void {
    for (let i = 0; i < this.myGroups.length; i++) {
      if (this.myGroups[i].groupId === groupId) {
        return
      }
    }
    this.myGroups = [...this.myGroups, { groupId: groupId, groupName: groupName, owner: owner, ownerAvatar: ownerAvatar }]
  }

  // 从myGroups移除群组
  private removeGroupFromMyGroups(groupId: string): void {
    let newList: GroupInfo[] = []
    for (let i = 0; i < this.myGroups.length; i++) {
      if (this.myGroups[i].groupId !== groupId) {
        newList.push(this.myGroups[i])
      }
    }
    this.myGroups = newList
  }

  // 同步friends到AppStorage
  private syncFriendsToAppStorage(): void {
    let arr: Record<string, string>[] = []
    for (let i = 0; i < this.friends.length; i++) {
      arr.push({ 'userId': this.friends[i].userId, 'username': this.friends[i].username, 'avatar': this.friends[i].avatar })
    }
    AppStorage.setOrCreate('friends', JSON.stringify(arr))
  }

  // 添加群组到AppStorage（Marvis建议4修复：补 members/owner 字段，与后端返回对齐，后续依赖 members 的逻辑不会空）
  private addGroupToAppStorage(groupObj: Record<string, Object>): void {
    let groupsStr = AppStorage.get<string>('groups')
    if (groupsStr === undefined) groupsStr = '[]'
    let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
    groupsArr.push(groupObj)
    AppStorage.setOrCreate('groups', JSON.stringify(groupsArr))
  }

  // 同步修改 AppStorage.groups 中某个群的 members 数组（成员加入/移出时用）
  private updateGroupMembersInAppStorage(groupId: string, updater: (members: string[]) => string[]): void {
    let groupsStr = AppStorage.get<string>('groups')
    if (groupsStr === undefined || groupsStr === '') return
    try {
      let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
      let changed = false
      for (let i = 0; i < groupsArr.length; i++) {
        if ((groupsArr[i]['groupId'] as string) === groupId) {
          let raw = groupsArr[i]['members']
          let members: string[] = []
          if (raw instanceof Array) {
            for (let j = 0; j < raw.length; j++) { members.push(String(raw[j])) }
          }
          groupsArr[i]['members'] = updater(members)
          changed = true
          break
        }
      }
      if (changed) AppStorage.setOrCreate('groups', JSON.stringify(groupsArr))
    } catch (_) { /* 忽略解析失败 */ }
  }

  // 从AppStorage移除群组
  private removeGroupFromAppStorage(groupId: string): void {
    let groupsStr = AppStorage.get<string>('groups')
    if (groupsStr === undefined) groupsStr = '[]'
    let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
    let newArr: Record<string, Object>[] = []
    for (let i = 0; i < groupsArr.length; i++) {
      if (groupsArr[i]['groupId'] !== groupId) {
        newArr.push(groupsArr[i])
      }
    }
    AppStorage.setOrCreate('groups', JSON.stringify(newArr))
  }

  // ========== 安全加固：被顶号善后 ==========
  // 服务端已经销毁了我们的会话并关了连接（WS管理器已拦停重连），这里只管本地收拾。
  // 注意不能调logout()：那个会给服务端发logout消息（会话已经没了，发了也白发），
  // 还会删preferences凭据——被顶号≠凭据失效，留着下次一键登录
  onKicked(): void {
    if (this.kickReason === '') {
      return // 复位空值触发的watch，忽略
    }
    AppStorage.setOrCreate('userId', '')
    AppStorage.setOrCreate('username', '')
    AppStorage.setOrCreate('avatar', '')
    AppStorage.setOrCreate('friends', '[]')
    AppStorage.setOrCreate('groups', '[]')
    AppStorage.setOrCreate('unreadCounts', '{}')
    AppStorage.setOrCreate('friendRequests', '[]')
    AppStorage.setOrCreate('groupJoinRequests', '[]')
    WebSocketManager.getInstance().clearPendingMessages()
    this.pageStack.clear()
    this.pageStack.pushPath({ name: 'LoginPage' })
    // kickReason不在这里清：留着给LoginPage读出来提示用户，它显示完自己复位
  }

  logout(): void {
    // 安全加固（Bug13修复）：先把登出消息发给服务端再断连接——顺序不能反，
    // disconnect()之后send()只会把消息压进离线队列，服务端永远收不到
    // （data字段不带——服务端logout处理只看type，省得为空对象声明类型）
    let logoutMsg: Record<string, string> = { 'type': 'logout' }
    WebSocketManager.getInstance().send(JSON.stringify(logoutMsg))
    AppStorage.setOrCreate('userId', '')
    AppStorage.setOrCreate('username', '')
    AppStorage.setOrCreate('avatar', '')
    AppStorage.setOrCreate('friends', '[]')
    AppStorage.setOrCreate('groups', '[]')
    // 安全加固：这三样以前漏清了——换账号登录后，上一个账号的未读数/申请列表会残留串号
    AppStorage.setOrCreate('unreadCounts', '{}')
    AppStorage.setOrCreate('friendRequests', '[]')
    AppStorage.setOrCreate('groupJoinRequests', '[]')
    // 清除WS重连回调，防止退出登录后WS重连又自动登录回来
    WebSocketManager.getInstance().setOnReconnect(undefined)
    // 安全加固：清空离线队列——里面是上一个账号发的消息，换账号登录后被flush出去就串号了
    WebSocketManager.getInstance().clearPendingMessages()
    WebSocketManager.getInstance().disconnect()
    try {
      let context = AppStorage.get<Context>('context')
      if (context !== undefined) {
        let pref = preferences.getPreferencesSync(context, { name: 'loginStore' })
        pref.deleteSync('username')
        pref.deleteSync('password')
        pref.flush(() => {})
      }
    } catch (e) {
      // 忽略
    }
    this.pageStack.clear()
    this.pageStack.pushPath({ name: 'LoginPage' })
  }

  // 点击会话，清除未读（前端+服务端+AppStorage持久化双向同步）
  clearUnread(targetId: string): void {
    let changed = false
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].targetId === targetId && this.conversations[i].unreadCount > 0) {
        this.conversations[i].unreadCount = 0
        changed = true
        break
      }
    }
    if (changed) {
      this.refreshConversations()
    }
    // ★★★ Bug1修复：把清0结果同步写回 AppStorage.unreadCounts（下次 aboutToAppear/onPageShow 读时不会"又出来红点"） ★★★
    this.syncUnreadCountsToAppStorage()
    // 通知服务端清零未读
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'targetId': targetId }
    let sendMsg: Record<string, Object> = { 'type': 'mark_read', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 查找或创建会话
  private findOrCreateConversation(type: string, targetId: string, name: string, avatar: string): Conversation {
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].targetId === targetId) {
        return this.conversations[i]
      }
    }
    // 不存在则创建
    let c = new Conversation()
    c.type = type
    c.targetId = targetId
    c.name = name
    c.avatar = avatar
    this.conversations.splice(0, 0, c)
    return c
  }

  // 更新会话的lastMessage并置顶（★ 每次更新都同步写回 AppStorage，解决 Bug2/3：红点不递增、最后一条消息不实时）
  private updateConversationLastMsg(targetId: string, lastMessage: string, addUnread: boolean): void {
    let found = false
    let conversationType = ''
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].targetId === targetId) {
        this.conversations[i].lastMessage = lastMessage
        let newTime = this.nowHHMM()
        this.conversations[i].lastTime = newTime
        conversationType = this.conversations[i].type
        if (addUnread) {
          // 统一用AppStorage里的currentChatTargetId判断（ChatPage入栈时设，出栈时清）
          let watching = AppStorage.get<string>('currentChatTargetId') ?? ''
          if (watching !== targetId) {
            // ★★★ Bug2修复：红点数量 +1，不是重置为1 ★★★
            this.conversations[i].unreadCount = this.conversations[i].unreadCount + 1
            // ★★★ Bug1修复：加完未读立刻同步写回 AppStorage.unreadCounts ★★★
            this.syncUnreadCountsToAppStorage()
          } else {
            // 正在看这个对话，也同步清一次（避免偶发重复推unread）
            if (this.conversations[i].unreadCount > 0) {
              this.conversations[i].unreadCount = 0
              this.syncUnreadCountsToAppStorage()
            }
          }
        }
        // ★★★ Bug3修复：lastMessage/lastTime 同步写回 AppStorage（friends/groups），下次进入页面仍能显示 ★★★
        this.syncLastMessageToAppStorage(targetId, conversationType, lastMessage, newTime)
        found = true
        break
      }
    }
    this.refreshConversations()
  }

  // 删除某个targetId的会话
  private removeConversation(targetId: string): void {
    let newList: Conversation[] = []
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].targetId !== targetId) {
        newList.push(this.conversations[i])
      }
    }
    this.conversations = newList
  }

  respondFriendRequest(fromUserId: string, agree: boolean): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = {
      'fromUserId': fromUserId,
      'agree': agree
    }
    let sendMsg: Record<string, Object> = {
      'type': 'friend_respond',
      'data': innerData
    }
    ws.send(JSON.stringify(sendMsg))
    if (agree) {
      let reqItem: FriendRequestItem | undefined = undefined
      for (let i = 0; i < this.friendRequests.length; i++) {
        if (this.friendRequests[i].fromUserId === fromUserId) {
          reqItem = this.friendRequests[i]
          break
        }
      }
      if (reqItem !== undefined) {
        this.friends.push({ userId: reqItem.fromUserId, username: reqItem.fromUsername, avatar: reqItem.fromAvatar })
        this.refreshFriends()
        this.syncFriendsToAppStorage()
        let c = new Conversation()
        c.type = 'private'
        c.targetId = reqItem.fromUserId
        c.name = reqItem.fromUsername
        c.avatar = reqItem.fromAvatar
        c.lastMessage = '已成为好友'
        c.lastTime = this.nowHHMM()
        this.conversations.splice(0, 0, c)
        this.refreshConversations()
        this.syncLastMessageToAppStorage(reqItem.fromUserId, 'private', '已成为好友', this.nowHHMM())
      }
    }
    // 移除该请求
    let newList: FriendRequestItem[] = []
    for (let i = 0; i < this.friendRequests.length; i++) {
      if (this.friendRequests[i].fromUserId !== fromUserId) {
        newList.push(this.friendRequests[i])
      }
    }
    this.friendRequests = newList
  }

  // WS消息总分发器（本页监听所有服务端推送）：
  //   好友：friend_request(来申请) / friend_response(对方同意) / friend_deleted(被删好友)
  //   群组：create_group_response / group_invite / group_join_response / group_member_joined /
  //         group_dissolved / group_self_left / group_self_kicked / group_kick / group_leave / group_join_request
  //   自己发的确认：*_sent → 只更新会话预览lastMessage（不加未读）
  //   实时消息：private_chat/group_chat/group_private → 更新预览 + 未读+1（自己发的直接return跳过）
  // 铁三角：凡是动了未读/最后一条，紧跟一个 sync 写回AppStorage，否则下次登录数据丢失
  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    // ===== 好友相关 =====
    if (msgType === 'friend_request') {
      let msgData = msg['data'] as Record<string, Object>
      // 避免重复：同一个fromUserId的申请只存一份未读
      let exists = false
      for (let i = 0; i < this.friendRequests.length; i++) {
        if (this.friendRequests[i].fromUserId === (msgData['fromUserId'] as string)) {
          exists = true
          break
        }
      }
      if (!exists) {
        this.friendRequests.push({
          fromUserId: msgData['fromUserId'] as string,
          fromUsername: msgData['fromUsername'] as string,
          fromAvatar: msgData['fromAvatar'] as string,
          unread: true
        })
      }
      let fn = msgData['fromUsername'] !== undefined && String(msgData['fromUsername']).length > 0
        ? String(msgData['fromUsername']) : '对方'
      this.showTip(`「${fn}」请求添加你为好友`)
      return
    }

    if (msgType === 'friend_response') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['agree'] === true) {
        let fUserId = msgData['fromUserId'] as string
        let fUsername = msgData['fromUsername'] as string
        let fAvatar = msgData['fromAvatar'] as string
        this.friends.push({ userId: fUserId, username: fUsername, avatar: fAvatar })
        this.refreshFriends()
        this.syncFriendsToAppStorage()
        let c = new Conversation()
        c.type = 'private'
        c.targetId = fUserId
        c.name = fUsername
        c.avatar = fAvatar
        c.lastMessage = '已成为好友'
        c.lastTime = this.nowHHMM()
        this.conversations.splice(0, 0, c)
        this.refreshConversations()
        this.syncLastMessageToAppStorage(fUserId, 'private', '已成为好友', this.nowHHMM())
        let fn = fUsername && fUsername.length > 0 ? fUsername : '对方'
        this.showTip(`你已与「${fn}」成为好友`)
      } else {
        let fn = msgData['fromUsername'] !== undefined && String(msgData['fromUsername']).length > 0
          ? String(msgData['fromUsername']) : '对方'
        this.showTip(`「${fn}」拒绝了你的好友申请`)
      }
      return
    }

    // ===== 群组相关 =====
    // 创建群组成功——群主自己添加群会话
    if (msgType === 'create_group_response') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['success'] === true) {
        let groupId = msgData['groupId'] as string
        let groupName = msgData['groupName'] as string
        let ownerAvatar = msgData['ownerAvatar'] as string
        // 避免重复
        let exists = false
        for (let i = 0; i < this.conversations.length; i++) {
          if (this.conversations[i].targetId === groupId) {
            exists = true
            break
          }
        }
        if (!exists) {
          let c = new Conversation()
          c.type = 'group'
          c.targetId = groupId
          c.name = groupName
          c.avatar = ownerAvatar
          c.lastMessage = '群组已创建'
          c.lastTime = this.nowHHMM()
          this.conversations.splice(0, 0, c)
          this.refreshConversations()
          this.addGroupToAppStorage({
            'groupId': groupId,
            'groupName': groupName,
            'ownerAvatar': ownerAvatar,
            'owner': msgData['owner'] as string,
            'members': (msgData['members'] as string[]) ?? []
          })
          this.addGroupToMyGroups(groupId, groupName, msgData['owner'] as string, ownerAvatar)
          this.syncLastMessageToAppStorage(groupId, 'group', '群组已创建', this.nowHHMM())
        }
      }
      return
    }

    if (msgType === 'group_invite') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      // 避免重复添加
      let exists = false
      for (let i = 0; i < this.conversations.length; i++) {
        if (this.conversations[i].targetId === groupId) {
          exists = true
          break
        }
      }
      if (!exists) {
        let c = new Conversation()
        c.type = 'group'
        c.targetId = groupId
        c.name = msgData['groupName'] as string
        c.avatar = msgData['ownerAvatar'] as string
        c.lastMessage = '你被邀请加入群组'
        c.lastTime = this.nowHHMM()
        this.conversations.splice(0, 0, c)
        this.refreshConversations()
        this.addGroupToAppStorage({
          'groupId': groupId,
          'groupName': msgData['groupName'],
          'ownerAvatar': msgData['ownerAvatar'],
          'owner': msgData['owner'] as string,
          'members': (msgData['members'] as string[]) ?? []
        })
        this.addGroupToMyGroups(groupId, msgData['groupName'] as string, msgData['owner'] as string, msgData['ownerAvatar'] as string)
        this.syncLastMessageToAppStorage(groupId, 'group', '你被邀请加入群组', this.nowHHMM())
      }
      return
    }

    if (msgType === 'group_join_response') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['agree'] === true) {
        let groupId = msgData['groupId'] as string
        let exists = false
        for (let i = 0; i < this.conversations.length; i++) {
          if (this.conversations[i].targetId === groupId) {
            exists = true
            break
          }
        }
        if (!exists) {
          let c = new Conversation()
          c.type = 'group'
          c.targetId = groupId
          c.name = msgData['groupName'] as string
          c.avatar = msgData['ownerAvatar'] as string
          c.lastMessage = '已加入群组'
          c.lastTime = this.nowHHMM()
          this.conversations.splice(0, 0, c)
          this.refreshConversations()
          this.addGroupToAppStorage({
            'groupId': groupId,
            'groupName': msgData['groupName'],
            'ownerAvatar': msgData['ownerAvatar'],
            'owner': msgData['owner'] as string,
            'members': (msgData['members'] as string[]) ?? []
          })
          this.addGroupToMyGroups(groupId, msgData['groupName'] as string, msgData['owner'] as string, msgData['ownerAvatar'] as string)
          this.syncLastMessageToAppStorage(groupId, 'group', '已加入群组', this.nowHHMM())
        }
      }
      return
    }

    // 群主同意入群后收到通知，更新群会话lastMessage + 同步AppStorage.groups[i].members（Marvis建议4修复，members字段与群成员同步）
    if (msgType === 'group_member_joined') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let joinUsername = msgData['username'] as string
      let joinUserId = msgData['userId'] as string
      // 同步 members：push 新成员
      this.updateGroupMembersInAppStorage(groupId, (members: string[]) => {
        if (members.indexOf(joinUserId) < 0) members.push(joinUserId)
        return members
      })
      this.updateConversationLastMsg(groupId, joinUsername + ' 加入了群组', false)
      return
    }

    if (msgType === 'group_dissolved') {
      let msgData = msg['data'] as Record<string, Object>
      let dissolvedGroupId = msgData['groupId'] as string
      let dissolvedGroupName = msgData['groupName'] !== undefined ? String(msgData['groupName']) : dissolvedGroupId
      this.removeConversation(dissolvedGroupId)
      this.removeGroupFromAppStorage(dissolvedGroupId)
      this.removeGroupFromMyGroups(dissolvedGroupId)
      this.systemNotifies.unshift({
        id: `dissolved_${dissolvedGroupId}_${Date.now()}`,
        type: 'group_dissolved',
        content: `群聊「${dissolvedGroupName}」已被群主解散`,
        timestamp: new Date().toLocaleString(),
        unread: true
      })
      return
    }

    if (msgType === 'group_join_request') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let fromUserId = msgData['fromUserId'] as string
      // 避免重复：同一个groupId+fromUserId的申请只存一份未读
      let exists = false
      for (let i = 0; i < this.groupRequests.length; i++) {
        if (this.groupRequests[i].groupId === groupId && this.groupRequests[i].fromUserId === fromUserId) {
          exists = true
          break
        }
      }
      if (!exists) {
        this.groupRequests.push({
          groupId: groupId,
          groupName: msgData['groupName'] as string,
          fromUserId: fromUserId,
          fromUsername: msgData['fromUsername'] as string,
          fromAvatar: msgData['fromAvatar'] as string,
          unread: true
        })
      }
      let gn = msgData['groupName'] !== undefined ? String(msgData['groupName']) : ''
      let fn = msgData['fromUsername'] !== undefined && String(msgData['fromUsername']).length > 0
        ? String(msgData['fromUsername']) : '对方'
      if (gn.length > 0) {
        this.showTip(`「${fn}」申请加入群「${gn}」`)
      } else {
        this.showTip(`「${fn}」发起了入群申请`)
      }
      return
    }

    // 自己被删好友——移除好友条目和对应会话 + Toast
    if (msgType === 'friend_deleted') {
      let msgData = msg['data'] as Record<string, Object>
      let byUserId = msgData['byUserId'] as string
      let byUsername = msgData['byUsername'] !== undefined && String(msgData['byUsername']).length > 0
        ? String(msgData['byUsername']) : byUserId
      let newFriends: FriendInfo[] = []
      for (let i = 0; i < this.friends.length; i++) {
        if (this.friends[i].userId !== byUserId) {
          newFriends.push(this.friends[i])
        }
      }
      this.friends = newFriends
      this.syncFriendsToAppStorage()
      this.removeConversation(byUserId)
      let tipName = byUsername && byUsername.length > 0 ? byUsername : '对方'
      this.showTip(`${tipName} 将您删除了好友`)
      this.systemNotifies.unshift({
        id: `friend_deleted_${byUserId}_${Date.now()}`,
        type: 'friend_deleted',
        content: `${tipName} 将您删除了好友`,
        timestamp: new Date().toLocaleString(),
        unread: true
      })
      return
    }

    // 自己退群后移除该群会话
    if (msgType === 'group_self_left') {
      let msgData = msg['data'] as Record<string, Object>
      let leftGroupId = msgData['groupId'] as string
      let leftGroupName = msgData['groupName'] !== undefined ? String(msgData['groupName']) : leftGroupId
      this.removeConversation(leftGroupId)
      this.removeGroupFromAppStorage(leftGroupId)
      this.removeGroupFromMyGroups(leftGroupId)
      if (leftGroupName && leftGroupName.length > 0) {
        this.showTip(`您已退出群聊「${leftGroupName}」`)
        this.systemNotifies.unshift({
          id: `self_left_${leftGroupId}_${Date.now()}`,
          type: 'group_self_left',
          content: `您已退出群聊「${leftGroupName}」`,
          timestamp: new Date().toLocaleString(),
          unread: true
        })
      }
      return
    }

    // 自己被踢出群——移除该群会话 + Toast
    if (msgType === 'group_self_kicked') {
      let msgData = msg['data'] as Record<string, Object>
      let kickedGroupId = msgData['groupId'] as string
      let kickedGroupName = msgData['groupName'] !== undefined ? String(msgData['groupName']) : kickedGroupId
      this.removeConversation(kickedGroupId)
      this.removeGroupFromAppStorage(kickedGroupId)
      this.removeGroupFromMyGroups(kickedGroupId)
      let tipName = kickedGroupName && kickedGroupName.length > 0 ? kickedGroupName : '某个群聊'
      this.showTip(`您已被移出群聊「${tipName}」`)
      this.systemNotifies.unshift({
        id: `self_kicked_${kickedGroupId}_${Date.now()}`,
        type: 'group_self_kicked',
        content: `您已被移出群聊「${tipName}」`,
        timestamp: new Date().toLocaleString(),
        unread: true
      })
      return
    }

    // 别人被踢出群——更新lastMessage + 同步移除 members（Marvis建议4修复）
    if (msgType === 'group_kick') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let targetUserId = msgData['targetUserId'] as string
      let targetUsername = msgData['targetUsername'] as string
      this.updateGroupMembersInAppStorage(groupId, (members: string[]) => {
        return members.filter(m => m !== targetUserId)
      })
      this.updateConversationLastMsg(groupId, targetUsername + ' 已被移出群组', false)
      return
    }

    // ===== 自己发消息的确认 =====
    if (msgType === 'private_chat_sent') {
      let msgData = msg['data'] as Record<string, Object>
      let targetUserId = msgData['targetUserId'] as string
      let content = msgData['content'] as string
      this.updateConversationLastMsg(targetUserId, content, false)
      return
    }

    if (msgType === 'group_chat_sent') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let content = msgData['content'] as string
      let myUsername = AppStorage.get<string>('username') ?? ''
      this.updateConversationLastMsg(groupId, myUsername + ': ' + content, false)
      return
    }

    if (msgType === 'group_private_sent') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let content = msgData['content'] as string
      let myUsername = AppStorage.get<string>('username') ?? ''
      this.updateConversationLastMsg(groupId, '[私聊] ' + myUsername + ': ' + content, false)
      return
    }

    // 别人退群——更新lastMessage + 同步移除 members（Marvis建议4修复）
    if (msgType === 'group_leave') {
      let msgData = msg['data'] as Record<string, Object>
      let groupId = msgData['groupId'] as string
      let leaveUserId = msgData['userId'] as string
      let leaveUsername = msgData['username'] as string
      this.updateGroupMembersInAppStorage(groupId, (members: string[]) => {
        return members.filter(m => m !== leaveUserId)
      })
      this.updateConversationLastMsg(groupId, leaveUsername + ' 退出了群聊', false)
      return
    }

    // ===== 收到实时消息 =====
    // 注意：后端广播给对端的消息 type 名分别是 private_chat / group_chat / group_private（和发送请求名一致）
    // Marvis BUG#1 确认：message.ts 第44行 type:'private_chat'，第98行 type:'group_chat'
    let targetId: string = ''
    let content: string = ''

    if (msgType === 'private_chat') {
      let msgData = msg['data'] as Record<string, Object>
      let myUserId = AppStorage.get<string>('userId')
      if (myUserId !== undefined && msgData['senderId'] === myUserId) {
        return
      }
      targetId = msgData['senderId'] as string
      content = msgData['content'] as string
      // 如果会话还没创建（比如新好友第一句话、或者被删除后重发），先找/建一个
      if (targetId !== '') {
        let exists = false
        for (let i = 0; i < this.conversations.length; i++) {
          if (this.conversations[i].targetId === targetId) { exists = true; break }
        }
        if (!exists) {
          // 从好友列表里找名字和头像，找不到就用默认
          let name = targetId
          let ava = 'youling'
          for (let j = 0; j < this.friends.length; j++) {
            if (this.friends[j].userId === targetId) {
              name = this.friends[j].username
              ava = this.friends[j].avatar
              break
            }
          }
          this.findOrCreateConversation('private', targetId, name, ava)
        }
      }
    } else if (msgType === 'group_chat') {
      let msgData = msg['data'] as Record<string, Object>
      targetId = msgData['groupId'] as string
      content = (msgData['senderUsername'] as string) + ': ' + (msgData['content'] as string)
      if (targetId !== '') {
        let exists = false
        for (let i = 0; i < this.conversations.length; i++) {
          if (this.conversations[i].targetId === targetId) { exists = true; break }
        }
        if (!exists) {
          // 从groups AppStorage里找群信息
          let groupsStr = AppStorage.get<string>('groups') ?? '[]'
          let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
          let name = targetId
          let ava = 'youling'
          for (let j = 0; j < groupsArr.length; j++) {
            if ((groupsArr[j]['groupId'] as string) === targetId) {
              name = groupsArr[j]['groupName'] as string
              ava = groupsArr[j]['ownerAvatar'] as string
              break
            }
          }
          this.findOrCreateConversation('group', targetId, name, ava)
        }
      }
    } else if (msgType === 'group_private') {
      let msgData = msg['data'] as Record<string, Object>
      targetId = msgData['groupId'] as string
      content = '[私聊] ' + (msgData['senderUsername'] as string) + ': ' + (msgData['content'] as string)
      if (targetId !== '') {
        // BUG#5 修复：group_private 同样兜底创建缺失会话，避免 updateConversationLastMsg 找不到 targetId
        let exists = false
        for (let i = 0; i < this.conversations.length; i++) {
          if (this.conversations[i].targetId === targetId) { exists = true; break }
        }
        if (!exists) {
          let groupsStr = AppStorage.get<string>('groups') ?? '[]'
          let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
          let name = targetId
          let ava = 'youling'
          for (let j = 0; j < groupsArr.length; j++) {
            if ((groupsArr[j]['groupId'] as string) === targetId) {
              name = groupsArr[j]['groupName'] as string
              ava = groupsArr[j]['ownerAvatar'] as string
              break
            }
          }
          this.findOrCreateConversation('group', targetId, name, ava)
        }
      }
    } else {
      return
    }

    // 更新会话lastMessage + 未读+1
    this.updateConversationLastMsg(targetId, content, true)
  }

  respondGroupJoin(groupId: string, fromUserId: string, agree: boolean): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = {
      'groupId': groupId,
      'fromUserId': fromUserId,
      'agree': agree
    }
    let sendMsg: Record<string, Object> = {
      'type': 'group_join_respond',
      'data': innerData
    }
    ws.send(JSON.stringify(sendMsg))

    if (agree) {
      // 群主同意：把新人写入AppStorage.groups对应群的members（避免下次登录又要重新拉）
      try {
        let groupsStr = AppStorage.get<string>('groups') ?? '[]'
        let groupsArr = JSON.parse(groupsStr) as Record<string, Object>[]
        for (let i = 0; i < groupsArr.length; i++) {
          if ((groupsArr[i]['groupId'] as string) === groupId) {
            let membersObj = groupsArr[i]['members'] as Object
            let membersArr: string[] = []
            if (membersObj !== undefined && membersObj !== null) {
              if (Array.isArray(membersObj)) {
                for (let k = 0; k < membersObj.length; k++) {
                  membersArr.push((membersObj as string[])[k] as string)
                }
              }
            }
            if (membersArr.indexOf(fromUserId) < 0) {
              membersArr.push(fromUserId)
              groupsArr[i]['members'] = membersArr
            }
            break
          }
        }
        AppStorage.setOrCreate('groups', JSON.stringify(groupsArr))
      } catch (e) {
      }

      // 同时刷新群会话的预览（"用户XXX已加入群组"）
      let reqItem: GroupRequestItem | undefined = undefined
      for (let i = 0; i < this.groupRequests.length; i++) {
        if (this.groupRequests[i].groupId === groupId && this.groupRequests[i].fromUserId === fromUserId) {
          reqItem = this.groupRequests[i]
          break
        }
      }
      if (reqItem !== undefined) {
        let groupName = reqItem.groupName
        let convPreview = `${reqItem.fromUsername} 已加入群组`
        this.updateConversationLastMsg(groupId, convPreview, false)
      }
    }

    // 移除该请求
    let newList: GroupRequestItem[] = []
    for (let i = 0; i < this.groupRequests.length; i++) {
      if (!(this.groupRequests[i].groupId === groupId && this.groupRequests[i].fromUserId === fromUserId)) {
        newList.push(this.groupRequests[i])
      }
    }
    this.groupRequests = newList
  }

  // 删除好友
  doDeleteFriend(targetUserId: string): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'targetUserId': targetUserId }
    let sendMsg: Record<string, Object> = { 'type': 'delete_friend', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
    // 本地立即移除好友和会话
    let newFriends: FriendInfo[] = []
    for (let i = 0; i < this.friends.length; i++) {
      if (this.friends[i].userId !== targetUserId) {
        newFriends.push(this.friends[i])
      }
    }
    this.friends = newFriends
    this.syncFriendsToAppStorage()
    this.removeConversation(targetUserId)
  }

  // 好友左滑删除按钮
  @Builder deleteFriendBuilder(item: FriendInfo) {
    Row() {
      Button('删除')
        .height('100%')
        .width(72)
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor('#F04848')
        .borderRadius(0)
        .onClick(() => {
          this.doDeleteFriend(item.userId)
        })
    }
  }

  // 跳转到聊天页面
  private goToChat(item: Conversation): void {
    this.clearUnread(item.targetId)
    this.currentChatTargetId = item.targetId
    let c = new Conversation()
    c.type = item.type
    c.targetId = item.targetId
    c.name = item.name
    c.avatar = item.avatar
    this.pageStack.pushPath({ name: 'ChatPage', param: c })
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 通用 Toast 浮层（showTip() 触发，3秒自动消失）=====
        if (this.tipText !== '') {
          Row() {
            Text(this.tipText)
              .fontSize(14)
              .fontColor(Color.White)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
          }
          .width('86%')
          .constraintSize({ minHeight: 40 })
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(0,0,0,0.78)')
          .borderRadius(20)
          .margin({ top: 16 })
          .zIndex(999)
        }

        Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
          // ===== Tab1: 消息 =====
          TabContent() {
            Column() {
              if (this.conversations.length > 0) {
                List({ space: 0 }) {
                ForEach(this.conversations, (item: Conversation) => {
                  ListItem() {
                    Row() {
                      // ===== 左侧：头像 + 右上角叠未读红圈（微信式） =====
                      Stack({ alignContent: Alignment.TopEnd }) {
                        Image($r(`app.media.${item.avatar && item.avatar.length > 0 ? item.avatar : 'youling'}`))
                          .width(52)
                          .height(52)
                          .borderRadius(8)
                        if (item.unreadCount > 0) {
                          Text(item.unreadCount > 99 ? '99+' : item.unreadCount.toString())
                            .fontSize(11)
                            .fontColor(Color.White)
                            .backgroundColor('#F04848')
                            .borderRadius(10)
                            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                            .margin({ top: -4, right: -6 }) // 向右上偏移，叠在头像边角
                            .constraintSize({ minWidth: 18, minHeight: 18 })
                            .textAlign(TextAlign.Center)
                            .fontWeight(FontWeight.Medium)
                        }
                      }
                      .width(56)
                      .height(56)

                      // ===== 右侧：两行文本（名字+时间 / 最后一条灰色预览） =====
                      Column() {
                        // 第一行：会话名（左）+ 时间（右）
                        Row() {
                          Text(item.name)
                            .fontSize(17)
                            .fontWeight(item.unreadCount > 0 ? FontWeight.Bold : FontWeight.Medium)
                            .fontColor('#222222')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .layoutWeight(1)
                          Text(item.lastTime)
                            .fontSize(12)
                            .fontColor('#B2B2B2')
                            .margin({ left: 8 })
                        }
                        .width('100%')

                        // 第二行：灰色消息预览（1行，长文本自动省略号）
                        Text(item.lastMessage && item.lastMessage.length > 0 ? item.lastMessage : ' ')
                          .fontSize(14)
                          .fontColor('#999999')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 5 })
                      }
                      .layoutWeight(1)
                      .margin({ left: 8 })
                      .alignItems(HorizontalAlign.Start)
                      .justifyContent(FlexAlign.Center)
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor(item.unreadCount > 0 ? '#FFFFFF' : '#FFFFFF')
                    .onClick(() => {
                      this.goToChat(item)
                    })
                  }
                }, (item: Conversation) => `${item.targetId}_${item.version}`)
              }
              .width('100%')
              .layoutWeight(1)
              .backgroundColor(Color.White)
              .divider({ strokeWidth: 1, color: '#EDEDED', startMargin: 88, endMargin: 0 })
              .alignListItem(ListItemAlign.Start)
            } else {
              Column() {
                Text('暂无消息')
                  .fontSize(16)
                  .fontColor('#BBBBBB')
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor('#EDEDED')
              }
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
          }
          .tabBar(this.TabWithBadge('消息', 0))

          // ===== Tab2: 好友 =====
          TabContent() {
            Stack() {
              Column() {
                List({ space: 0 }) {
                  // 好友分区标题
                  ListItem() {
                    Text('好友')
                      .fontSize(14)
                      .fontColor('#999999')
                      .width('100%')
                      .padding({ left: 16, top: 12, bottom: 8 })
                  }
                  if (this.friends.length > 0) {
                    ForEach(this.friends, (item: FriendInfo) => {
                      ListItem() {
                        Row() {
                          Image($r(`app.media.${item.avatar && item.avatar.length > 0 ? item.avatar : 'youling'}`))
                            .width(48)
                            .height(48)
                            .borderRadius(8)
                          Text(item.username)
                            .fontSize(17)
                            .fontColor('#333333')
                            .margin({ left: 12 })
                            .layoutWeight(1)
                        }
                        .width('100%')
                        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                        .alignItems(VerticalAlign.Center)
                        .onClick(() => {
                          let c = new Conversation()
                          c.type = 'private'
                           c.targetId = item.userId
                           c.name = item.username
                          c.avatar = item.avatar
                          this.goToChat(c)
                        })
                      }
                      .swipeAction({
                        end: {
                          builder: () => {
                            this.deleteFriendBuilder(item)
                          },
                          actionAreaDistance: 72
                        }
                      })
                    }, (item: FriendInfo) => item.userId)
                  } else {
                    ListItem() {
                      Text('暂无好友')
                        .fontSize(14)
                        .fontColor('#BBBBBB')
                        .width('100%')
                        .textAlign(TextAlign.Center)
                        .padding({ top: 8, bottom: 8 })
                    }
                  }
                  // 群组分区标题
                  ListItem() {
                    Text('群组')
                      .fontSize(14)
                      .fontColor('#999999')
                      .width('100%')
                      .padding({ left: 16, top: 16, bottom: 8 })
                  }
                  if (this.myGroups.length > 0) {
                    ForEach(this.myGroups, (item: GroupInfo) => {
                      ListItem() {
                        Row() {
                          Image($r(`app.media.${item.ownerAvatar && item.ownerAvatar.length > 0 ? item.ownerAvatar : 'youling'}`))
                            .width(48)
                            .height(48)
                            .borderRadius(8)
                          Column() {
                            Text(item.groupName)
                              .fontSize(17)
                              .fontColor('#333333')
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                          .margin({ left: 12 })
                          .layoutWeight(1)
                          .alignItems(HorizontalAlign.Start)
                        }
                        .width('100%')
                        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                        .alignItems(VerticalAlign.Center)
                        .onClick(() => {
                          let c = new Conversation()
                          c.type = 'group'
                          c.targetId = item.groupId
                          c.name = item.groupName
                          c.avatar = item.ownerAvatar
                          this.goToChat(c)
                        })
                      }
                    }, (item: GroupInfo) => item.groupId)
                  } else {
                    ListItem() {
                      Text('暂无群组')
                        .fontSize(14)
                        .fontColor('#BBBBBB')
                        .width('100%')
                        .textAlign(TextAlign.Center)
                        .padding({ top: 8, bottom: 8 })
                    }
                  }
                }
                .width('100%')
                .layoutWeight(1)
                .backgroundColor(Color.White)
                .divider({ strokeWidth: 1, color: '#ECECEC', startMargin: 76, endMargin: 0 })
                .alignListItem(ListItemAlign.Start)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Start)

              // 右上角 "+" 浮动按钮
              Stack() {
                Column() {
                  Text('+')
                    .fontSize(28)
                    .fontColor(Color.White)
                    .fontWeight(FontWeight.Normal)
                }
                .width(44)
                .height(44)
                .backgroundColor('#07C160')
                .borderRadius(22)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
              }
              .position({ x: '82%', y: 12 })
              .zIndex(5)
              .onClick(() => {
                this.showFriendMenu = !this.showFriendMenu
              })

              // 弹出菜单
              if (this.showFriendMenu) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#44000000')
                  .onClick(() => {
                    this.showFriendMenu = false
                  })
                Column() {
                  Row() {
                    Text('添加好友')
                      .fontSize(16)
                      .fontColor(Color.White)
                  }
                  .width('100%')
                  .height(48)
                  .padding({ left: 20, right: 20 })
                  .onClick(() => {
                    this.showFriendMenu = false
                    this.pageStack.pushPath({ name: 'AddFriendPage' })
                  })
                  Divider().color('#666666')
                  Row() {
                    Text('创建群组')
                      .fontSize(16)
                      .fontColor(Color.White)
                  }
                  .width('100%')
                  .height(48)
                  .padding({ left: 20, right: 20 })
                  .onClick(() => {
                    this.showFriendMenu = false
                    this.pageStack.pushPath({ name: 'CreateGroupPage' })
                  })
                  Divider().color('#666666')
                  Row() {
                    Text('搜索群组')
                      .fontSize(16)
                      .fontColor(Color.White)
                  }
                  .width('100%')
                  .height(48)
                  .padding({ left: 20, right: 20 })
                  .onClick(() => {
                    this.showFriendMenu = false
                    this.pageStack.pushPath({ name: 'SearchGroupPage' })
                  })
                }
                .width(140)
                .backgroundColor('#4C4C4C')
                .borderRadius(8)
                .position({ x: '60%', y: 12 })
                .zIndex(20)
              }
            }
            .width('100%')
            .layoutWeight(1)
          }
          .tabBar(this.TabWithBadge('好友', 1))

          // ===== Tab3: 通知 =====
          TabContent() {
            Column() {
              if (this.friendRequests.length > 0 || this.groupRequests.length > 0 || this.systemNotifies.length > 0) {
                Scroll() {
                  Column() {
                    if (this.friendRequests.length > 0 || this.groupRequests.length > 0) {
                      Text('申请')
                        .fontSize(14)
                        .fontColor('#999999')
                        .width('100%')
                        .padding({ left: 16, top: 16, bottom: 8 })
                    }
                    if (this.friendRequests.length > 0) {
                      Column() {
                        ForEach(this.friendRequests, (req: FriendRequestItem) => {
                          Stack({ alignContent: Alignment.TopEnd }) {
                            Row() {
                              Image($r(`app.media.${req.fromAvatar && req.fromAvatar.length > 0 ? req.fromAvatar : 'youling'}`))
                                .width(44)
                                .height(44)
                                .borderRadius(22)
                              Column() {
                                Text(req.fromUsername)
                                  .fontSize(16)
                                  .fontColor('#333333')
                                Text('请求添加你为好友')
                                  .fontSize(13)
                                  .fontColor('#999999')
                                  .margin({ top: 2 })
                              }
                              .margin({ left: 12 })
                              .layoutWeight(1)
                              .alignItems(HorizontalAlign.Start)
                              Row() {
                                Button('同意')
                                  .height(32)
                                  .fontSize(13)
                                  .fontColor(Color.White)
                                  .backgroundColor('#07C160')
                                  .borderRadius(16)
                                  .padding({ left: 12, right: 12 })
                                  .margin({ right: 8 })
                                  .onClick(() => {
                                    this.respondFriendRequest(req.fromUserId, true)
                                  })
                                Button('拒绝')
                                  .height(32)
                                  .fontSize(13)
                                  .fontColor('#666666')
                                  .backgroundColor('#F0F0F0')
                                  .borderRadius(16)
                                  .padding({ left: 12, right: 12 })
                                  .onClick(() => {
                                    this.respondFriendRequest(req.fromUserId, false)
                                  })
                              }
                            }
                            .width('100%')
                            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                            if (req.unread) {
                              Circle({ width: 10, height: 10 })
                                .fill('#F04848')
                                .margin({ top: 8, right: 8 })
                                .zIndex(99)
                            }
                          }
                          .width('100%')
                        }, (req: FriendRequestItem) => req.fromUserId)
                      }
                      .width('100%')
                      .backgroundColor(Color.White)
                      .borderRadius(12)
                      .margin({ left: 16, right: 16 })
                    }

                    if (this.groupRequests.length > 0) {
                      Column() {
                        ForEach(this.groupRequests, (req: GroupRequestItem) => {
                          Stack({ alignContent: Alignment.TopEnd }) {
                            Row() {
                              Column() {
                                Text(req.fromUsername)
                                  .fontSize(16)
                                  .fontColor('#333333')
                                Text(`申请加入「${req.groupName}」`)
                                  .fontSize(13)
                                  .fontColor('#999999')
                                  .margin({ top: 2 })
                              }
                              .layoutWeight(1)
                              .alignItems(HorizontalAlign.Start)
                              Row() {
                                Button('同意')
                                  .height(32)
                                  .fontSize(13)
                                  .fontColor(Color.White)
                                  .backgroundColor('#07C160')
                                  .borderRadius(16)
                                  .padding({ left: 12, right: 12 })
                                  .margin({ right: 8 })
                                  .onClick(() => {
                                    this.respondGroupJoin(req.groupId, req.fromUserId, true)
                                  })
                                Button('拒绝')
                                  .height(32)
                                  .fontSize(13)
                                  .fontColor('#666666')
                                  .backgroundColor('#F0F0F0')
                                  .borderRadius(16)
                                  .padding({ left: 12, right: 12 })
                                  .onClick(() => {
                                    this.respondGroupJoin(req.groupId, req.fromUserId, false)
                                  })
                              }
                            }
                            .width('100%')
                            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                            if (req.unread) {
                              Circle({ width: 10, height: 10 })
                                .fill('#F04848')
                                .margin({ top: 8, right: 8 })
                                .zIndex(99)
                            }
                          }
                          .width('100%')
                        }, (req: GroupRequestItem) => `${req.groupId}_${req.fromUserId}`)
                      }
                      .width('100%')
                      .backgroundColor(Color.White)
                      .borderRadius(12)
                      .margin({ left: 16, right: 16, top: 8 })
                    }

                    if (this.systemNotifies.length > 0) {
                      Text('通知')
                        .fontSize(14)
                        .fontColor('#999999')
                        .width('100%')
                        .padding({ left: 16, top: 20, bottom: 8 })
                      Column() {
                        ForEach(this.systemNotifies, (notify: SystemNotify) => {
                          Stack({ alignContent: Alignment.TopEnd }) {
                            Row() {
                              Column() {
                                Text(notify.content)
                                  .fontSize(15)
                                  .fontColor('#333333')
                                  .maxLines(2)
                                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                                Text(notify.timestamp)
                                  .fontSize(12)
                                  .fontColor('#B2B2B2')
                                  .margin({ top: 4 })
                              }
                              .layoutWeight(1)
                              .alignItems(HorizontalAlign.Start)
                            }
                            .width('100%')
                            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                            if (notify.unread) {
                              Circle({ width: 10, height: 10 })
                                .fill('#F04848')
                                .margin({ top: 8, right: 8 })
                                .zIndex(99)
                            }
                          }
                          .width('100%')
                        }, (notify: SystemNotify) => notify.id)
                      }
                      .width('100%')
                      .backgroundColor(Color.White)
                      .borderRadius(12)
                      .margin({ left: 16, right: 16 })
                    }
                  }
                  .width('100%')
                }
                .width('100%')
                .layoutWeight(1)
                .backgroundColor('#EDEDED')
                .scrollBar(BarState.Auto)
              } else {
                Column() {
                  Text('暂无通知')
                    .fontSize(16)
                    .fontColor('#BBBBBB')
                }
                .width('100%')
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('#EDEDED')
              }
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Start)
          }
          .tabBar(this.TabWithBadge('通知', 2))

          // ===== Tab4: 我的 =====
          TabContent() {
            Column() {
              Column() {
                Row() {
                  Image($r(`app.media.${this.avatar && this.avatar.length > 0 ? this.avatar : 'youling'}`))
                    .width(64)
                    .height(64)
                    .borderRadius(8)
                  Column() {
                    Text(this.username)
                      .fontSize(20)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#333333')
                    Text(`ID: ${this.userId}`)
                      .fontSize(14)
                      .fontColor('#999999')
                      .margin({ top: 4 })
                  }
                  .margin({ left: 16 })
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding(20)
                .backgroundColor(Color.White)
              }
              .width('100%')
              .margin({ top: 8 })

              Column() {
                Row() {
                  Text('设置')
                    .fontSize(16)
                    .fontColor('#333333')
                    .layoutWeight(1)
                  Text('>')
                    .fontSize(16)
                    .fontColor('#CCCCCC')
                }
                .width('100%')
                .padding(16)
                .onClick(() => {
                  this.showSettingsTip = true
                })
              }
              .width('100%')
              .backgroundColor(Color.White)
              .margin({ top: 8 })

              // 设置页的简易提示浮层（当前还没有专门的设置页面，先给个说明）
              if (this.showSettingsTip) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#55000000')
                  .position({ x: 0, y: 0 })
                  .zIndex(10)
                  .onClick(() => {
                    this.showSettingsTip = false
                  })
                Column() {
                  Text('设置')
                    .fontSize(18)
                    .fontColor('#333333')
                    .fontWeight(FontWeight.Medium)
                    .margin({ bottom: 16 })
                  Text('目前为 v1.0 版本，设置页面正在开发中。\n你可以通过下方按钮退出登录切换账号。')
                    .fontSize(15)
                    .fontColor('#666666')
                    .textAlign(TextAlign.Center)
                    .margin({ bottom: 24 })
                  Button('知道了')
                    .width(160)
                    .height(40)
                    .fontSize(15)
                    .fontColor(Color.White)
                    .backgroundColor('#07C160')
                    .borderRadius(20)
                    .onClick(() => {
                      this.showSettingsTip = false
                    })
                }
                .width('80%')
                .padding(24)
                .backgroundColor(Color.White)
                .borderRadius(12)
                .position({ x: '10%', y: '35%' })
                .zIndex(20)
              }

              Column() {
                Row() {
                  Text('退出登录')
                    .fontSize(16)
                    .fontColor('#F04848')
                    .layoutWeight(1)
                }
                .width('100%')
                .padding(16)
              }
              .width('100%')
              .backgroundColor(Color.White)
              .margin({ top: 8 })
              .onClick(() => {
                this.logout()
              })
            }
            .width('100%')
            .height('100%')
            .backgroundColor('#EDEDED')
            .justifyContent(FlexAlign.Start)
          }
          .tabBar(this.TabWithBadge('我的', 3))
        }
        .width('100%')
        .layoutWeight(1)
        .barMode(BarMode.Fixed)
        .barBackgroundColor(Color.White)
        .onChange((index: number) => {
          this.currentTab = index
          this.showFriendMenu = false
          // 切到通知Tab时，把所有friend/group申请的小红点清零
          if (index === 2) {
            this.clearNotifyTabUnread()
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#EDEDED')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
    }
    .title('MyChat')
    .hideTitleBar(true)
    .onShown(() => {
      this.currentChatTargetId = ''
      AppStorage.setOrCreate('currentChatTargetId', '')
      this.syncFromAppStorage()
    })
  }
}

@Builder
export function ChatListPageBuilder() {
  ChatListPage()
}
