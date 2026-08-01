@Observed
export class Conversation {
  type: string = 'private'
  targetId: string = ''
  name: string = ''
  avatar: string = ''
  lastMessage: string = ''
  lastTime: string = ''
  unreadCount: number = 0
  version: number = 0
}