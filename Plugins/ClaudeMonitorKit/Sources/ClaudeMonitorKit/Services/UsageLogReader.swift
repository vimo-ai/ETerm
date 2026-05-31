import Foundation

// 100% 5h 窗口 ≈ 17.6% 7d 配额（实测经验值）
enum WaveConstants {
    static let sevenDayPerFullWave: Double = 17.6
    static let fiveHourWindowSeconds: TimeInterval = 5 * 3600
}

/// 从 ~/.vimo/usage-log.jsonl 读取当前波的速度
enum UsageLogReader {

    private struct LogEntry {
        let ts: Int    // epoch ms
        let sd: Int    // 7-day %
        let fh: Int    // 5-hour %
    }

    private static let logPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.vimo/usage-log.jsonl"
    }()

    /// 读取当前波的速度 (min per 1% 7d)，无法计算时返回 nil
    static func readCurrentSpeed() -> Double? {
        guard FileManager.default.fileExists(atPath: logPath) else { return nil }

        guard let entries = readTailEntries() else { return nil }

        let currentWave = extractCurrentWave(from: entries)
        guard currentWave.count >= 5 else { return nil }

        let first = currentWave[0]
        let last = currentWave[currentWave.count - 1]

        let elapsedHours = Double(last.ts - first.ts) / 3_600_000
        let fhConsumed = last.fh - first.fh
        guard elapsedHours >= 0.08, fhConsumed >= 5 else { return nil }

        let sdConsumed = last.sd - first.sd
        guard sdConsumed > 0 else { return nil }

        return (elapsedHours * 60) / Double(sdConsumed)
    }

    // MARK: - Private

    private static func readTailEntries() -> [LogEntry]? {
        guard let fh = FileHandle(forReadingAtPath: logPath) else { return nil }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let tailBytes: UInt64 = min(100_000, fileSize)
        fh.seek(toFileOffset: fileSize - tailBytes)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        // 截断的首行丢弃
        if fileSize > tailBytes, !lines.isEmpty {
            lines.removeFirst()
        }

        var entries: [LogEntry] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = obj["ts"] as? Int,
                  let sd = obj["sd"] as? Int,
                  let fh = obj["fh"] as? Int else { continue }
            entries.append(LogEntry(ts: ts, sd: sd, fh: fh))
        }
        return entries
    }

    /// 从尾部向前找当前波：fh 单调递增段，回落 >10 说明跨波
    private static func extractCurrentWave(from entries: [LogEntry]) -> [LogEntry] {
        var wave: [LogEntry] = []
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            if !wave.isEmpty, entries[i].fh > wave[0].fh + 10 {
                break
            }
            wave.insert(entries[i], at: 0)
        }
        return wave
    }
}
