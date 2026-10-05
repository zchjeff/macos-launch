import Foundation
import Security

/// 随机密码的生成参数。
///
/// 与 `QRCodeOptions` 同为一组纯值参数，放在 Core 侧、可脱离界面直接测。
public struct PasswordOptions: Hashable, Sendable {
    /// 期望长度；实际生成前会被夹进 `PasswordGenerator.minimumLength...maximumLength`。
    public var length: Int
    public var includesLowercase: Bool
    public var includesUppercase: Bool
    public var includesDigits: Bool
    public var includesSymbols: Bool
    /// 排除易混淆字符（`0 O 1 l I`）。
    public var excludesAmbiguous: Bool

    public init(
        length: Int = 16,
        includesLowercase: Bool = true,
        includesUppercase: Bool = true,
        includesDigits: Bool = true,
        includesSymbols: Bool = false,
        excludesAmbiguous: Bool = false
    ) {
        self.length = length
        self.includesLowercase = includesLowercase
        self.includesUppercase = includesUppercase
        self.includesDigits = includesDigits
        self.includesSymbols = includesSymbols
        self.excludesAmbiguous = excludesAmbiguous
    }
}

/// 无法生成密码的原因。
public enum PasswordError: Error, Equatable, Sendable {
    /// 所有字符集都关掉了，字符池为空——与其生成一个空密码，不如说清楚。
    case emptyCharacterSets
    /// 系统安全随机源不可用（极罕见）。宁可报错，也不退回弱随机。
    case randomSourceFailed

    public var localizedDescription: String {
        switch self {
        case .emptyCharacterSets: "至少选择一种字符集。"
        case .randomSourceFailed: "系统安全随机源不可用，无法生成密码。"
        }
    }
}

/// 随机密码的纯计算逻辑。
///
/// ## 为什么走 `SecRandomCopyBytes` 而不是 `Int.random`
/// 密码的随机必须是**密码学安全**的：`SystemRandomNumberGenerator`（`Int.random` 背后的引擎）
/// 是面向速度的伪随机，不保证不可预测，不能用于密钥材料。`SecRandomCopyBytes` 直接取
/// 系统 CSPRNG，是 macOS 上的正确选择。这也是本模块**唯一**引入的系统框架（`Security`）——
/// 它不是 UI 框架，测试环境无需运行时即可调用，与 AppBoxCore「不依赖 AppKit / CoreImage」的惯例不冲突。
///
/// ## 为什么用拒绝采样而不是 `%`
/// 直接 `randomByte % 字符池大小` 会引入**取模偏置**：当池大小不整除 256（或 2³²）时，
/// 靠前的一部分字符被选中的概率略高。对密码而言这是可利用的熵损失。这里按
/// `arc4random_uniform` 的做法设一道拒绝阈值，落在偏置区间就重取，得到均匀分布。
public enum PasswordGenerator {
    public static let minimumLength = 4
    public static let maximumLength = 128

    /// 各字符集。刻意写死 ASCII 子集：工具只做纯计算，不跟随本地化字符表。
    static let lowercase = "abcdefghijklmnopqrstuvwxyz"
    static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let digits = "0123456789"
    static let symbols = "!@#$%^&*()-_=+[]{};:,.<>/?"

    /// 易混淆字符集。用户开「排除」时从字符池里剔掉这些。
    public static let ambiguousCharacters: Set<Character> = ["0", "O", "1", "l", "I"]

    /// 按参数组装字符池（已应用易混淆排除）。
    ///
    /// 空字符集 → 空池，调用方据此判定「至少要选一种字符集」。
    public static func pool(options: PasswordOptions) -> String {
        var characters = ""
        if options.includesLowercase { characters += lowercase }
        if options.includesUppercase { characters += uppercase }
        if options.includesDigits { characters += digits }
        if options.includesSymbols { characters += symbols }
        if options.excludesAmbiguous {
            characters = String(characters.filter { !ambiguousCharacters.contains($0) })
        }
        return characters
    }

    /// 生成一个密码。
    ///
    /// 允许字符重复（有放回抽样）：这样长度与字符池大小解耦，长度可远超池容量而不失败；
    /// 对随机密码而言重复本就是正常现象。
    ///
    /// - Throws: 池为空时 `.emptyCharacterSets`；安全随机源失败时 `.randomSourceFailed`。
    public static func generate(options: PasswordOptions) throws(PasswordError) -> String {
        let characters = Array(pool(options: options))
        guard !characters.isEmpty else { throw .emptyCharacterSets }

        let length = min(max(options.length, minimumLength), maximumLength)
        let limit = UInt32(characters.count)
        // 拒绝阈值：落在 [0, minAcceptable) 的随机数会被丢弃，以消除取模偏置。
        // (0 &- limit) 在无符号回绕下等于 2³² - limit，再 % limit 即 2³² % limit。
        let minAcceptable = (0 &- limit) % limit

        var result = ""
        result.reserveCapacity(length)
        var value: UInt32 = 0

        for _ in 0..<length {
            while true {
                let status = SecRandomCopyBytes(
                    kSecRandomDefault,
                    MemoryLayout<UInt32>.size,
                    &value
                )
                guard status == errSecSuccess else { throw .randomSourceFailed }
                if value >= minAcceptable { break }
            }
            result.append(characters[Int(value % limit)])
        }
        return result
    }
}
