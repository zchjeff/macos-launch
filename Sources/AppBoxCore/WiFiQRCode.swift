import Foundation

/// WiFi 二维码的加密方式。
///
/// 只列标准 `WIFI:` 载荷真正区分的三类：WPA 家族（WPA/WPA2/WPA3 在载荷里都写成 `WPA`）、
/// WEP、以及无密码。扫码端（iOS / Android 相机）认的就是这套 `T:` 取值，
/// 细分到 WPA3 反而不被识别，所以这里刻意不铺更细的档位。
public enum WiFiEncryption: String, CaseIterable, Hashable, Sendable {
    case wpa
    case wep
    case none

    public var displayName: String {
        switch self {
        case .wpa: "WPA/WPA2"
        case .wep: "WEP"
        case .none: "无密码"
        }
    }

    /// 写进载荷 `T:` 字段的值。
    public var typeToken: String {
        switch self {
        case .wpa: "WPA"
        case .wep: "WEP"
        case .none: "nopass"
        }
    }

    /// 是否需要密码。无密码时载荷里不写 `P:` 字段，界面也应忽略密码输入。
    public var requiresPassword: Bool { self != .none }
}

/// 生成 WiFi 二维码载荷（`WIFI:` 文本）的纯逻辑。
///
/// 与 `QRCode` 一样待在 `AppBoxCore`：只依赖 Foundation，把「字段拼装 + 转义 + 校验」
/// 这套最容易写错的规则脱离图形栈单测。真正的出图仍交给 `QRCodeRendering` 端口。
///
/// 载荷格式（事实标准，各扫码端通用）：
/// `WIFI:T:<加密>;S:<名称>;P:<密码>;H:<隐藏>;;`
/// 末尾恒为两个分号：一个收尾最后一个字段，一个终止整条载荷。
public enum WiFiQRCode {
    /// 载荷文本里必须转义的字符：反斜杠与几个分隔符。
    /// 不转义会让含 `;` `:` `,` 的密码被扫码端截断。
    private static let escapable: Set<Character> = ["\\", ";", ",", ":", "\""]

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptySSID
        case emptyPassword

        public var localizedDescription: String {
            switch self {
            case .emptySSID:
                "请先填写 WiFi 名称（SSID）"
            case .emptyPassword:
                "该加密方式需要密码，请填写 WiFi 密码"
            }
        }
    }

    /// 拼出可直接编码进二维码的 `WIFI:` 载荷。
    ///
    /// SSID 全空白视为未填；选了下拉里非「无密码」的加密方式时，空密码报错。
    public static func payload(
        ssid: String,
        password: String,
        encryption: WiFiEncryption,
        isHidden: Bool
    ) throws(Error) -> String {
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptySSID
        }
        if encryption.requiresPassword {
            guard !password.isEmpty else { throw .emptyPassword }
        }

        var result = "WIFI:T:\(encryption.typeToken);S:\(escape(ssid));"
        if encryption.requiresPassword {
            result += "P:\(escape(password));"
        }
        if isHidden {
            result += "H:true;"
        }
        result += ";"
        return result
    }

    /// 对载荷字段做反斜杠转义。
    static func escape(_ text: String) -> String {
        guard text.contains(where: { escapable.contains($0) }) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if escapable.contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }
}
