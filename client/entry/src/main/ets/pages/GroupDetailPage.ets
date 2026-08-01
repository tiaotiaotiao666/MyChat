import WebSocketManager from '../model/WebSocketManager'
import { Conversation } from '../model/Conversation'

// 群成员数据结构
interface GroupMember {
  userId: string
  username: string
  avatar: string
  isOwner: boolean
}

// 可邀请的好友数据
interface InviteFriend {
  userId: string
  username: string
  avatar: string
  selected: boolean
}

@Component
struct GroupDetailPage {
  @Consume('pageStack') pageStack: NavPathStack
  @State groupId: string = ''
  @State groupName: string = ''
  @State ownerAvatar: string = ''
  @State isOwner: boolean = false
  @State members: GroupMember[] = []
  @State showConfirm: boolean = false // 确认弹窗
  @State confirmAction: string = '' // 'dissolve' / 'leave' / 'kick'
  @State kickTargetUserId: string = ''
  @State kickTargetUsername: string = ''
  @State showInvitePanel: boolean = false // 邀请好友面板
  @State inviteFriends: InviteFriend[] = [] // 可邀请的好友列表（不在群内的好友）
  @State inviteDone: boolean = false // 邀请完成标记
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  aboutToAppear(): void {
    // 从路由参数获取群信息
    let params = this.pageStack.getParamByName('GroupDetailPage')[0] as Conversation
    if (params !== undefined && params !== null) {
      this.groupId = params.targetId
      this.groupName = params.name
      this.ownerAvatar = params.avatar
    }
    // isOwner 暂设 false，等 group_members_response 返回后从服务端数据设置
    this.isOwner = false
    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
    // 请求群成员列表
    this.requestMembers()
  }

  aboutToDisappear(): void {
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  // 请求群成员列表
  private requestMembers(): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupId': this.groupId }
    let sendMsg: Record<string, Object> = { 'type': 'group_members', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 构建可邀请好友列表（不在群内的好友）
  private buildInviteFriendsList(): void {
    // 获取群内成员ID集合
    let memberIds: string[] = []
    for (let i = 0; i < this.members.length; i++) {
      memberIds.push(this.members[i].userId)
    }
    // 获取好友列表，过滤已在群内的
    let friendsStr = AppStorage.get<string>('friends')
    if (friendsStr === undefined) {
      friendsStr = '[]'
    }
    let friendsArr = JSON.parse(friendsStr) as Record<string, Object>[]
    let list: InviteFriend[] = []
    for (let i = 0; i < friendsArr.length; i++) {
      let fId = friendsArr[i]['userId'] as string
      let inGroup = false
      for (let j = 0; j < memberIds.length; j++) {
        if (memberIds[j] === fId) {
          inGroup = true
          break
        }
      }
      if (!inGroup) {
        list.push({
          userId: fId,
          username: friendsArr[i]['username'] as string,
          avatar: friendsArr[i]['avatar'] as string,
          selected: false
        })
      }
    }
    this.inviteFriends = list
    this.inviteDone = false
  }

  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    // 收到群成员列表 — 从服务端数据设置 isOwner，不依赖 AppStorage 快照
    if (msgType === 'group_members_response') {
      let msgData = msg['data'] as Record<string, Object>
      let membersArr = msgData['members'] as Record<string, Object>[]
      let list: GroupMember[] = []
      let myUserId = AppStorage.get<string>('userId') ?? ''
      for (let i = 0; i < membersArr.length; i++) {
        let isOwner = membersArr[i]['isOwner'] as boolean
        list.push({
          userId: membersArr[i]['userId'] as string,
          username: membersArr[i]['username'] as string,
          avatar: membersArr[i]['avatar'] as string,
          isOwner: isOwner
        })
        // 自己是群主则标记
        if (membersArr[i]['userId'] === myUserId && isOwner) {
          this.isOwner = true
        }
      }
      this.members = list
      return
    }

    // 群解散后返回聊天列表（只 pop 一次，回到 ChatPage）
    if (msgType === 'group_dissolved') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.groupId) {
        this.pageStack.pop()
      }
      return
    }

    // 退群后返回聊天列表（只 pop 一次，回到 ChatPage）
    if (msgType === 'group_self_left') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.groupId) {
        this.pageStack.pop()
      }
      return
    }

    // 被踢后返回聊天列表（只 pop 一次，回到 ChatPage）
    if (msgType === 'group_self_kicked') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.groupId) {
        this.pageStack.pop()
      }
      return
    }

    // 有人被踢，刷新成员列表
    if (msgType === 'group_kick') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['groupId'] === this.groupId) {
        let targetId = msgData['targetUserId'] as string
        let newList: GroupMember[] = []
        for (let i = 0; i < this.members.length; i++) {
          if (this.members[i].userId !== targetId) {
            newList.push(this.members[i])
          }
        }
        this.members = newList
      }
      return
    }

    // 邀请好友入群成功（收到system消息"已邀请入群"）
    // 注意：邀请多人时后端会逐个发 system，不要第一条就置 inviteDone
    // 改为：doInvite 结束后统一标记 inviteDone，不在这里设
    if (msgType === 'system') {
      let msgData = msg['data'] as Record<string, Object>
      let text = msgData['text'] as string
      if (text !== undefined && text.indexOf('已邀请入群') >= 0) {
        // 刷新成员列表
        this.requestMembers()
      }
    }
  }

  // 执行解散群组
  doDissolve(): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupId': this.groupId }
    let sendMsg: Record<string, Object> = { 'type': 'group_dissolve', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 执行退出群组
  doLeave(): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupId': this.groupId }
    let sendMsg: Record<string, Object> = { 'type': 'group_leave', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 执行踢人
  doKick(): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupId': this.groupId, 'targetUserId': this.kickTargetUserId }
    let sendMsg: Record<string, Object> = { 'type': 'group_kick', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 邀请选中的好友入群
  doInvite(): void {
    let ws = WebSocketManager.getInstance()
    let hasSelected = false
    for (let i = 0; i < this.inviteFriends.length; i++) {
      if (this.inviteFriends[i].selected) {
        hasSelected = true
        let innerData: Record<string, Object> = {
          'groupId': this.groupId,
          'targetUserId': this.inviteFriends[i].userId
        }
        let sendMsg: Record<string, Object> = { 'type': 'group_invite', 'data': innerData }
        ws.send(JSON.stringify(sendMsg))
      }
    }
    // 所有邀请发完后统一标记完成
    if (hasSelected) {
      this.inviteDone = true
    }
  }

  build() {
    NavDestination() {
      Stack() {
        // ===== 主内容 =====
        Column() {
          // 群信息区域
          Column() {
            Image($r(`app.media.${this.ownerAvatar && this.ownerAvatar.length > 0 ? this.ownerAvatar : 'youling'}`))
              .width(72)
              .height(72)
              .borderRadius(12)
            Text(this.groupName)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#333333')
              .margin({ top: 12 })
            Text(`群ID: ${this.groupId}`)
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 4 })
          }
          .width('100%')
          .padding({ top: 24, bottom: 16 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(Color.White)

          // 群成员列表标题
          Row() {
            Text('群成员')
              .fontSize(16)
              .fontColor('#333333')
              .fontWeight(FontWeight.Medium)
            Text(`(${this.members.length}人)`)
              .fontSize(14)
              .fontColor('#999999')
              .margin({ left: 6 })
          }
          .width('100%')
          .padding({ left: 16, top: 16, bottom: 8 })

          // 群成员列表
          if (this.members.length > 0) {
            List({ space: 0 }) {
              ForEach(this.members, (item: GroupMember) => {
                ListItem() {
                  Row() {
                    Image($r(`app.media.${item.avatar && item.avatar.length > 0 ? item.avatar : 'youling'}`))
                      .width(44)
                      .height(44)
                      .borderRadius(22)
                    Column() {
                      Text(item.isOwner ? `${item.username}（群主）` : item.username)
                        .fontSize(16)
                        .fontColor('#333333')
                    }
                    .margin({ left: 12 })
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    // 群主视角：可以踢非群主成员
                    if (this.isOwner && !item.isOwner) {
                      Button('移出')
                        .height(32)
                        .fontSize(13)
                        .fontColor('#F04848')
                        .backgroundColor('#FFF0F0')
                        .borderRadius(16)
                        .padding({ left: 12, right: 12 })
                        .onClick(() => {
                          this.kickTargetUserId = item.userId
                          this.kickTargetUsername = item.username
                          this.confirmAction = 'kick'
                          this.showConfirm = true
                        })
                    }
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .backgroundColor(Color.White)
                  .alignItems(VerticalAlign.Center)
                }
              }, (item: GroupMember) => item.userId)
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 1, color: '#F0F0F0', startMargin: 72, endMargin: 16 })
          } else {
            Column() {
              Text('加载中...')
                .fontSize(14)
                .fontColor('#999999')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }

          // 底部操作区域
          Column() {
            // 邀请好友入群按钮
            Button('邀请好友入群')
              .width('90%')
              .height(44)
              .fontSize(16)
              .fontColor('#07C160')
              .backgroundColor(Color.White)
              .borderRadius(8)
              .margin({ bottom: 8 })
              .onClick(() => {
                this.buildInviteFriendsList()
                this.showInvitePanel = true
              })

            if (this.isOwner) {
              Button('解散群组')
                .width('90%')
                .height(48)
                .fontSize(18)
                .fontColor('#F04848')
                .backgroundColor(Color.White)
                .borderRadius(8)
                .margin({ bottom: 16 })
                .onClick(() => {
                  this.confirmAction = 'dissolve'
                  this.showConfirm = true
                })
            } else {
              Button('退出群组')
                .width('90%')
                .height(48)
                .fontSize(18)
                .fontColor('#F04848')
                .backgroundColor(Color.White)
                .borderRadius(8)
                .margin({ bottom: 16 })
                .onClick(() => {
                  this.confirmAction = 'leave'
                  this.showConfirm = true
                })
            }
          }
          .width('100%')
          .padding({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F5F5F5')
        .alignItems(HorizontalAlign.Center)

        // ===== 邀请好友面板 =====
        if (this.showInvitePanel) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.showInvitePanel = false
            })

          Column() {
            Text('邀请好友入群')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .margin({ bottom: 16 })

            if (this.inviteFriends.length > 0) {
              List({ space: 0 }) {
                ForEach(this.inviteFriends, (item: InviteFriend) => {
                ListItem() {
                  Row() {
                    Image($r(`app.media.${item.avatar && item.avatar.length > 0 ? item.avatar : 'youling'}`))
                      .width(40)
                      .height(40)
                      .borderRadius(20)
                      Text(item.username)
                        .fontSize(16)
                        .fontColor('#333333')
                        .margin({ left: 12 })
                        .layoutWeight(1)
                      Checkbox()
                        .select(item.selected)
                        .selectedColor('#07C160')
                        .onChange((isChecked: boolean) => {
                          for (let j = 0; j < this.inviteFriends.length; j++) {
                            if (this.inviteFriends[j].userId === item.userId) {
                              this.inviteFriends[j].selected = isChecked
                              break
                            }
                          }
                          this.inviteFriends = [...this.inviteFriends]
                        })
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .alignItems(VerticalAlign.Center)
                  }
                }, (item: InviteFriend) => item.userId)
              }
              .width('100%')
              .height(300)
              .divider({ strokeWidth: 1, color: '#F0F0F0', startMargin: 68, endMargin: 16 })

              if (this.inviteDone) {
                Text('邀请已发送！')
                  .fontSize(16)
                  .fontColor('#07C160')
                  .margin({ top: 12 })
              }

              Row() {
                Button('取消')
                  .width(120)
                  .height(40)
                  .fontSize(16)
                  .fontColor('#666666')
                  .backgroundColor('#F0F0F0')
                  .borderRadius(20)
                  .onClick(() => {
                    this.showInvitePanel = false
                  })
                Button('邀请')
                  .width(120)
                  .height(40)
                  .fontSize(16)
                  .fontColor(Color.White)
                  .backgroundColor('#07C160')
                  .borderRadius(20)
                  .margin({ left: 16 })
                  .onClick(() => {
                    this.doInvite()
                  })
              }
              .margin({ top: 16 })
            } else {
              Text('没有可邀请的好友')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ top: 40, bottom: 40 })
              Button('关闭')
                .width(120)
                .height(40)
                .fontSize(16)
                .fontColor('#666666')
                .backgroundColor('#F0F0F0')
                .borderRadius(20)
                .onClick(() => {
                  this.showInvitePanel = false
                })
            }
          }
          .width('85%')
          .padding(20)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .alignItems(HorizontalAlign.Center)
        }

        // ===== 确认弹窗 =====
        if (this.showConfirm) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.showConfirm = false
            })

          Column() {
            if (this.confirmAction === 'kick') {
              Text(`确认将 ${this.kickTargetUsername} 移出群组？`)
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#333333')
                .margin({ bottom: 8 })
              Text('移出后该用户将不再收到群消息')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ bottom: 24 })
            } else if (this.confirmAction === 'dissolve') {
              Text('确认解散群组？')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#333333')
                .margin({ bottom: 8 })
              Text('解散后所有成员将被移出，无法恢复')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ bottom: 24 })
            } else {
              Text('确认退出群组？')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#333333')
                .margin({ bottom: 8 })
              Text('退出后将不再收到群消息')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ bottom: 24 })
            }

            Row() {
              Button('取消')
                .width(120)
                .height(40)
                .fontSize(16)
                .fontColor('#666666')
                .backgroundColor('#F0F0F0')
                .borderRadius(20)
                .onClick(() => {
                  this.showConfirm = false
                })
              Button('确认')
                .width(120)
                .height(40)
                .fontSize(16)
                .fontColor(Color.White)
                .backgroundColor('#F04848')
                .borderRadius(20)
                .margin({ left: 16 })
                .onClick(() => {
                  this.showConfirm = false
                  if (this.confirmAction === 'dissolve') {
                    this.doDissolve()
                  } else if (this.confirmAction === 'leave') {
                    this.doLeave()
                  } else if (this.confirmAction === 'kick') {
                    this.doKick()
                  }
                })
            }
          }
          .width('80%')
          .padding(24)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('群聊信息')
    .hideTitleBar(false)
  }
}

@Builder
export function GroupDetailPageBuilder() {
  GroupDetailPage()
}
