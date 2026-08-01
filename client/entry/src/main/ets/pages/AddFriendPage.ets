import WebSocketManager from '../model/WebSocketManager'

// 搜索结果的数据结构
interface SearchResult {
  userId: string
  username: string
  avatar: string
}

@Component
struct AddFriendPage {
  @Consume('pageStack') pageStack: NavPathStack
  @State searchText: string = ''
  @State searchResult: SearchResult | undefined = undefined
  @State searchDone: boolean = false
  @State requestSent: boolean = false
  private messageHandler = (data: string) => {
    this.onMessage(data)
  }

  aboutToAppear(): void {
    WebSocketManager.getInstance().addMessageListener(this.messageHandler)
  }

  aboutToDisappear(): void {
    WebSocketManager.getInstance().removeMessageListener(this.messageHandler)
  }

  onMessage(data: string): void {
    let msg = JSON.parse(data) as Record<string, Object>
    let msgType = msg['type'] as string

    if (msgType === 'friend_search_response') {
      let msgData = msg['data'] as Record<string, Object>
      this.searchDone = true
      if (msgData['found'] === true) {
        let result: SearchResult = {
          userId: msgData['userId'] as string,
          username: msgData['username'] as string,
          avatar: msgData['avatar'] as string
        }
        this.searchResult = result
      } else {
        this.searchResult = undefined
      }
    } else if (msgType === 'system') {
      let msgData = msg['data'] as Record<string, Object>
      let text = msgData['text'] as string
      if (text.indexOf('好友请求已发送') >= 0) {
        this.requestSent = true
      }
    } else if (msgType === 'friend_request_response') {
      // 后端直接返回friend_request_response(已好友情况): success=false+error
      let msgData = msg['data'] as Record<string, Object>
      if (msgData['success'] === false) {
        // 无论如何标记一下"已发送/已是好友"避免用户重复点
        this.requestSent = true
      }
    } else if (msgType === 'error') {
      // 后端返回错误（重复申请/已是好友）→ 按钮灰掉
      this.requestSent = true
    }
  }

  doSearch(): void {
    if (this.searchText.trim() === '') {
      return
    }
    this.searchDone = false
    this.searchResult = undefined
    this.requestSent = false
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'username': this.searchText }
    let sendMsg: Record<string, Object> = { 'type': 'friend_search', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  sendRequest(): void {
    if (this.searchResult === undefined) {
      return
    }
    let ws = WebSocketManager.getInstance()
    let innerData: Record<string, Object> = { 'targetUserId': this.searchResult.userId }
    let sendMsg: Record<string, Object> = { 'type': 'friend_request', 'data': innerData }
    ws.send(JSON.stringify(sendMsg))
  }

  build() {
    NavDestination() {
      Column() {
        // 搜索栏
        Row() {
          TextInput({ placeholder: '输入用户名搜索', text: this.searchText })
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
          if (this.searchResult !== undefined) {
            Column() {
              Row() {
                Image($r(`app.media.${(this.searchResult !== undefined && this.searchResult.avatar && this.searchResult.avatar.length > 0) ? this.searchResult.avatar : 'youling'}`))
                  .width(52)
                  .height(52)
                  .borderRadius(8)
                Column() {
                  Text(this.searchResult.username)
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#333333')
                  Text(this.searchResult.userId)
                    .fontSize(14)
                    .fontColor('#999999')
                    .margin({ top: 2 })
                }
                .margin({ left: 12 })
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (this.requestSent) {
                  Text('已发送')
                    .fontSize(14)
                    .fontColor('#07C160')
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor('#E8F8EE')
                    .borderRadius(16)
                } else {
                  Button('添加')
                    .height(36)
                    .fontSize(14)
                    .fontColor(Color.White)
                    .backgroundColor('#07C160')
                    .borderRadius(18)
                    .padding({ left: 16, right: 16 })
                    .onClick(() => {
                      this.sendRequest()
                    })
                }
              }
              .width('100%')
              .padding(16)
            }
            .width('100%')
            .backgroundColor(Color.White)
            .margin({ top: 16 })
          } else {
            Column() {
              Text('未找到该用户')
                .fontSize(16)
                .fontColor('#999999')
            }
            .width('100%')
            .height(120)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.White)
            .margin({ top: 16 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5F5')
      .alignItems(HorizontalAlign.Center)
    }
    .title('添加好友')
    .hideTitleBar(false)
  }
}

@Builder
export function AddFriendPageBuilder() {
  AddFriendPage()
}
