import WebSocketManager from '../model/WebSocketManager'

// 群组搜索结果的数据结构
interface GroupResult {
  groupId: string
  groupName: string
  ownerAvatar: string
  memberCount: number
}

@Component
struct SearchGroupPage {
  @Consume('pageStack') pageStack: NavPathStack
  @State searchText: string = ''
  @State searchResults: GroupResult[] = []
  @State searchDone: boolean = false
  // 用数组记录所有已发送过入群申请的 groupId，解决一次只能记一个、system消息把'groupId'覆盖成'sent'导致UI消失的问题
  @State pendingGroupIds: string[] = []
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  aboutToAppear(): void {
    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
  }

  aboutToDisappear(): void {
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  // 判断某个群是否已经发送过申请（用数组，支持多个群独立判断）
  private isGroupPending(groupId: string): boolean {
    for (let i = 0; i < this.pendingGroupIds.length; i++) {
      if (this.pendingGroupIds[i] === groupId) {
        return true
      }
    }
    return false
  }

  // 将某个群标记为已申请（避免重复标记）
  private markGroupPending(groupId: string): void {
    if (this.isGroupPending(groupId)) {
      return
    }
    let newArr: string[] = [...this.pendingGroupIds]
    newArr.push(groupId)
    this.pendingGroupIds = newArr
  }

  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    if (msgType === 'group_search_response') {
      let msgData = msg['data'] as Record<string, Object>
      this.searchDone = true
      let groups = msgData['groups'] as Record<string, Object>[]
      let list: GroupResult[] = []
      for (let i = 0; i < groups.length; i++) {
        let g: GroupResult = {
          groupId: groups[i]['groupId'] as string,
          groupName: groups[i]['groupName'] as string,
          ownerAvatar: groups[i]['ownerAvatar'] as string,
          memberCount: groups[i]['members'] as number
        }
        list.push(g)
      }
      this.searchResults = list
    } else if (msgType === 'system') {
      let msgData = msg['data'] as Record<string, Object>
      let text = msgData['text'] as string
      // 后端返回"入群申请已发送给群主 xxx"，格式里带groupId；如果解析不到groupId就不改pending，之前本地加的标记仍然生效
      if (text.indexOf('入群申请已发送') >= 0) {
        let targetId = msgData['groupId'] as string
        if (targetId !== undefined && targetId !== null && targetId !== '') {
          this.markGroupPending(targetId)
        }
      }
    }
  }

  doSearch(): void {
    if (this.searchText.trim() === '') {
      return
    }
    this.searchDone = false
    this.searchResults = []
    // 注意：不清空 pendingGroupIds，因为这是当前会话的有效状态；如果用户想重置可以重新进入页面
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupName': this.searchText }
    let sendMsg: Record<string, Object> = { 'type': 'group_search', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  sendJoinRequest(groupId: string): void {
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'groupId': groupId }
    let sendMsg: Record<string, Object> = { 'type': 'group_join_request', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
    // 本地立即标记为待审核，确保UI立刻显示"已申请"
    this.markGroupPending(groupId)
  }

  build() {
    NavDestination() {
      Column() {
        // 搜索栏
        Row() {
          TextInput({ placeholder: '输入群名搜索', text: this.searchText })
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .backgroundColor('#F5F5F5')
            .borderRadius(22)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.searchText = value
            })
          Button('搜索')
            .height(44)
            .width(72)
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor('#07C160')
            .borderRadius(22)
            .margin({ left: 10 })
            .onClick(() => {
              this.doSearch()
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })

        // 搜索结果
        if (this.searchDone) {
          if (this.searchResults.length > 0) {
            List({ space: 0 }) {
              ForEach(this.searchResults, (item: GroupResult) => {
                ListItem() {
                  Row() {
                    // 群头像（用群主头像）内联空值兜底，ArkTS build内不能写let声明
                    Image($r(`app.media.${item.ownerAvatar && item.ownerAvatar.length > 0 ? item.ownerAvatar : 'youling'}`))
                      .width(52)
                      .height(52)
                      .borderRadius(8)
                    Column() {
                      Text(item.groupName)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#333333')
                      Text(`${item.memberCount}人`)
                        .fontSize(14)
                        .fontColor('#999999')
                        .margin({ top: 2 })
                    }
                    .margin({ left: 12 })
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    // 申请按钮
                    if (this.isGroupPending(item.groupId)) {
                      Text('已申请')
                        .fontSize(14)
                        .fontColor('#07C160')
                        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                        .backgroundColor('#E8F8EE')
                        .borderRadius(16)
                    } else {
                      Button('加入')
                        .height(36)
                        .fontSize(14)
                        .fontColor(Color.White)
                        .backgroundColor('#07C160')
                        .borderRadius(18)
                        .padding({ left: 16, right: 16 })
                        .onClick(() => {
                          this.sendJoinRequest(item.groupId)
                        })
                    }
                  }
                  .width('100%')
                  .padding(16)
                  .backgroundColor(Color.White)
                }
              }, (item: GroupResult) => item.groupId)
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 1, color: '#F0F0F0', startMargin: 80, endMargin: 16 })
            .margin({ top: 12 })
          } else {
            Column() {
              Text('未找到相关群组')
                .fontSize(16)
                .fontColor('#999999')
            }
            .width('100%')
            .height(120)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.White)
            .margin({ top: 12 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5F5')
      .alignItems(HorizontalAlign.Center)
    }
    .title('搜索群组')
    .hideTitleBar(false)
  }
}

@Builder
export function SearchGroupPageBuilder() {
  SearchGroupPage()
}
