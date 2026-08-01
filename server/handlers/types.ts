
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
}