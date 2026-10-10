// ============================================================
// Conversation —— 会话：会话列表（聊天Tab）里的一行就是一个 Conversation
// 私聊(type='private')和群聊(type='group')共用同一个类，列表行代码只写一遍
// ============================================================
@Observed // V1观察者：配合 @ObjectLink 才能让列表项的属性变化触发刷新
export class Conversation {
  type: string = 'private'   // 'private'=好友私聊 / 'group'=群聊
  targetId: string = ''      // 对方userId 或 群groupId——会话唯一标识，清未读/跳聊天页都按它
  name: string = ''          // 昵称 / 群名（列表行标题）
  avatar: string = ''        // 头像资源名（群聊存的是群主头像）
  lastMessage: string = ''   // 最后一条消息预览（列表行副标题）
  lastTime: string = ''      // 最后消息时间（显示HH:MM，排序比较也用它）
  unreadCount: number = 0    // 未读红点数（>0时头像右上角出现红圈）
  version: number = 0        // 强制刷新计数器：原地改数组内属性不触发UI刷新时，clone一份version+1整体替换
}