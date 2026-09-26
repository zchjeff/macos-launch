import AppBoxCore
import Foundation

/// 调试命令 `AppBox --scan`：打印真实扫描结果并退出。
///
/// 003 刻意不含 UI，验证出口就是这条命令——扫描与去重是最容易出错的部分，
/// 先在没有窗口牵扯的地方做扎实。
enum ScanCommand {
    static func run() {
        let scanner = AppScanner()
        let cache = IconCache(directory: AppBoxIdentity.iconsDirectory)
        let renderer = SystemIconRenderer()

        let scanStart = Date()
        let records = scanner.scan()
        let scanDuration = Date().timeIntervalSince(scanStart)

        print("扫描到 \(records.count) 个应用，耗时 \(formatted(scanDuration))")

        let iconStart = Date()
        var cached = 0
        var rows: [String] = []
        for record in records {
            let iconURL = cache.iconURL(for: record, renderer: renderer)
            if iconURL != nil { cached += 1 }
            rows.append(
                [
                    padded(record.displayName, 28),
                    padded(record.bundleIdentifier, 42),
                    padded(record.directory.rawValue, 20),
                    record.category ?? "-",
                ].joined(separator: "  ")
            )
        }
        let iconDuration = Date().timeIntervalSince(iconStart)

        print(rows.joined(separator: "\n"))
        print("")
        print("图标：\(cached)/\(records.count) 已缓存，耗时 \(formatted(iconDuration))")
        print("缓存目录：\(AppBoxIdentity.iconsDirectory.path)")
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    /// 按显示宽度粗略对齐；中文字符占两列，所以不能用 `String.count`。
    private static func padded(_ text: String, _ width: Int) -> String {
        let displayWidth = text.reduce(0) { total, character in
            total + (character.unicodeScalars.first.map { $0.value > 0x2000 ? 2 : 1 } ?? 1)
        }
        return text + String(repeating: " ", count: max(1, width - displayWidth))
    }
}
