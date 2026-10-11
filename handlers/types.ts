
export interface IncomingMessage {
    type: string;
    data: Record<string, unknown>;
}

export interface OutgoingMessage {
    type: string;
    data: Record<string, unknown>;
}

export interface ClientContext{
    userId: string | null;
    ws: {send: (data: string) => void};
    // 安全加固#2：心跳存活标记——每轮ping前置false，收到pong置回true；
    // 定时器发现连续两轮都是false，就判这条连接已经死了
    isAlive?: boolean;
}