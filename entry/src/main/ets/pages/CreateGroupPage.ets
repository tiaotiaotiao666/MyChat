// ============================================================
// CreateGroupPage —— 创建群组页
// 流程：填群名 → 勾选好友成员 → create_group → 成功提示1.2秒后自动返回
// 注意：成功后不自己push会话——AppStorage.groups/会话列表由 ChatListPage
//       的全局 create_group_response 监听统一处理（带去重），这里只管提示
// ============================================================
import WebSocketManager from '../model/WebSocketManager'

// 好友列表项的数据结构（多一个selected勾选态）
interface FriendItem {
  userId: string
  username: string
  avatar: string
  selected: boolean // 是否勾选为群成员（点Checkbox改，改完整体刷新）
}

@Component
struct CreateGroupPage {
  @Consume('pageStack') pageStack: NavPathStack // 跳转栈
  @State groupName: string = '' // 群名输入
  @State friends: FriendItem[] = [] // 可选成员（从AppStorage.friends恢复）
  @State created: boolean = false // 创建成功提示条显隐
  @State createdGroupName: string = '' // 成功提示里显示的群名
  @State tipText: string = '' // Toast文字
  private tipTimerId: number = -1 // Toast定时器
  // WS回调：箭头类字段终生绑this（通用写法）
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  // ========== 通用浮层 Toast ==========
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

  // 进页面：登记WS监听 + 从AppStorage.friends恢复好友（JSON串→对象，供勾选）
  aboutToAppear(): void {
    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
    let friendsStr = AppStorage.get<string>('friends')
    if (friendsStr === undefined) {
      friendsStr = '[]'
    }
    let friendsArr = JSON.parse(friendsStr) as Record<string, Object>[]
    let list: FriendItem[] = []
    for (let i = 0; i < friendsArr.length; i++) {
      let f: FriendItem = {
        userId: friendsArr[i]['userId'] as string,
        username: friendsArr[i]['username'] as string,
        avatar: friendsArr[i]['avatar'] as string,
        selected: false
      }
      list.push(f)
    }
    this.friends = list
  }

  aboutToDisappear(): void {
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    // 后端返回创建群失败的error（群名已存在/空名等），直接Toast 错误信息
    if (msgType === 'error') {
      let msgData = msg['data'] as Record<string, Object>
      let errMsg = msgData['message'] !== undefined ? String(msgData['message']) : '创建群聊失败，请稍后重试'
      this.showTip(errMsg)
      return
    }

    // 后端创建群组只返回 create_group_response，不再发 system
    if (msgType === 'create_group_response') {
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['success'] === true) {
        let groupId = msgData['groupId'] as string
        let groupName = msgData['groupName'] as string
        let ownerAvatar = msgData['ownerAvatar'] as string
        this.created = true
        this.createdGroupName = groupName
        // 注意：AppStorage.groups / 会话列表 已由 chatListPage 的全局 create_group_response 监听统一添加且带exists去重
        // 这里不要再重复push，否则会出现重复群组记录

        // ② 1.2秒后自动返回消息列表（给用户看一眼创建成功提示）
        setTimeout(() => {
          if (this.pageStack.size() > 0) {
            this.pageStack.pop()
          }
        }, 1200)
      }
    }
  }

  // 校验(群名/至少1人) → 收集勾选的memberIds → 发create_group，等响应走onMessage
  createGroup(): void {
    if (this.groupName.trim() === '') {
      this.showTip('请输入群名称')
      return
    }
    let memberIds: string[] = []
    for (let i = 0; i < this.friends.length; i++) {
      if (this.friends[i].selected) {
        memberIds.push(this.friends[i].userId)
      }
    }
    if (memberIds.length <= 0) {
      this.showTip('请至少选择一位群成员')
      return
    }
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupName': this.groupName, 'memberIds': memberIds }
    let sendMsg: Record<string, Object> = { 'type': 'create_group', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  // 获取已选中的成员数量
  private getSelectedCount(): number {
    let count = 0
    for (let i = 0; i < this.friends.length; i++) {
      if (this.friends[i].selected) {
        count++
      }
    }
    return count
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 通用 Toast 浮层 =====
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

        // 群名输入
        Column() {
          Text('群名称')
            .fontSize(14)
            .fontColor('#999999')
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: '输入群名称', text: this.groupName })
            .width('100%')
            .height(44)
            .fontSize(16)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.groupName = value
            })
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)

        // 成员选择标题
        Row() {
          Text('选择成员')
            .fontSize(14)
            .fontColor('#999999')
          Text(`已选 ${this.getSelectedCount()} 人`)
            .fontSize(14)
            .fontColor('#07C160')
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })

        // 好友列表
        if (this.friends.length > 0) {
          List({ space: 0 }) {
            ForEach(this.friends, (item: FriendItem) => {
              ListItem() {
                Row() {
                  Image($r(`app.media.${item.avatar && item.avatar.length > 0 ? item.avatar : 'youling'}`))
                    .width(44)
                    .height(44)
                    .borderRadius(8)
                  Text(item.username)
                    .fontSize(16)
                    .fontColor('#333333')
                    .margin({ left: 12 })
                    .layoutWeight(1)
                    Checkbox()
                     .select(item.selected)
                     .selectedColor('#07C160')
                     .onChange((isChecked: boolean) => {
                       // 找到对应好友更新selected，然后整体刷新数组
                       for (let j = 0; j < this.friends.length; j++) {
                         if (this.friends[j].userId === item.userId) {
                           this.friends[j].selected = isChecked
                           break
                         }
                       }
                       this.friends = [...this.friends]
                     })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor(Color.White)
              }
            }, (item: FriendItem) => item.userId)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: '#F0F0F0', startMargin: 72, endMargin: 16 })
        } else {
          Column() {
            Text('暂无好友，先去添加好友吧')
              .fontSize(14)
              .fontColor('#999999')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }

        // 创建成功提示
        if (this.created) {
          Row() {
            Text('✓')
              .fontSize(16)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
              .margin({ right: 8 })
            Text(`群组「${this.createdGroupName}」创建成功！`)
              .fontSize(16)
              .fontColor(Color.White)
          }
          .width('90%')
          .height(48)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#07C160')
          .borderRadius(24)
          .margin({ top: 8, bottom: 8 })
        }

        // 创建按钮
        Button('创建群组')
          .width('90%')
          .height(48)
          .fontSize(18)
          .fontColor(Color.White)
          .backgroundColor('#07C160')
          .borderRadius(24)
          .margin({ top: 8, bottom: 16 })
          .onClick(() => {
            this.createGroup()
          })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5F5')
      .alignItems(HorizontalAlign.Center)
    }
    .title('创建群组')
    .hideTitleBar(false)
  }
}

@Builder
export function CreateGroupPageBuilder() {
  CreateGroupPage()
}
