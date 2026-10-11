// ============================================================
// fsutil —— 数据文件的"安全读写"公共件（安全加固#9）
// ------------------------------------------------------------
// 为什么需要它：以前所有store都是 writeFileSync 直接覆盖 + JSON.parse 裸解析——
//   ① 进程在写盘写一半时被杀/断电 → JSON文件损坏 → 下次启动解析即崩（服务起不来）
//   ② 数据文件被手改坏一个字符 → 同样启动即崩
// 两个药方：
//   atomicWriteFileSync：先写 .tmp 再 rename——rename在同一盘上是原子操作，
//     任何时刻盘上要么是旧完整文件、要么是新完整文件，不存在"写了一半"的状态
//   safeReadJson：解析失败返回兜底值 + 报警日志，服务照常启动（数据坏了能诊断、不致命）
// ============================================================
import * as fs from 'fs';

// 原子写盘：临时文件 + 改名，杜绝"写一半"的中间态
export function atomicWriteFileSync(file: string, data: string): void {
    const tmp = file + '.tmp';
    fs.writeFileSync(tmp, data, 'utf-8');
    fs.renameSync(tmp, file);
}

// 带容错的JSON读取：坏了不崩，返回兜底值并大声报警
export function safeReadJson<T>(file: string, fallback: T): T {
    try {
        if (!fs.existsSync(file)) return fallback;
        const raw = fs.readFileSync(file, 'utf-8');
        if (raw.trim() === '') return fallback;
        return JSON.parse(raw) as T;
    } catch (e) {
        console.error(`[存储] ${file} 损坏或不可读，已用兜底数据启动（请检查该文件！）`, e);
        return fallback;
    }
}
