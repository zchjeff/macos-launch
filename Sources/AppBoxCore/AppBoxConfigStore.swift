import Foundation

/// 配置文件的读取结果。
///
/// 用返回值而不是抛错来表达「读到了什么」：高版本这一档**不携带配置**，
/// 调用方就没法拿默认配置顶上去继续跑，只能显式处理。
public enum ConfigLoadOutcome: Sendable, Equatable {
    /// 正常读到配置。
    case loaded(AppBoxConfig)
    /// 文件不存在，这是首次启动——默认配置尚未落盘，由调用方决定何时写。
    case createdDefault(AppBoxConfig)
    /// 文件读不出来，已改名为 `backup` 保住原始内容，用默认配置继续。
    case recoveredFromCorruption(AppBoxConfig, backup: URL)
    /// 文件的 schema 版本本程序认不了，既没读也没动它。
    case refusedUnsupportedSchema(found: Int, supported: Int)
}

public enum ConfigStoreError: Error, Equatable {
    /// 方案名不能用作文件名。
    case invalidProfileName(String)
    /// schema 版本比当前代码旧，且没有从那一版升上来的迁移路径。
    case unsupportedSchema(Int)
    /// 磁盘上已有一份版本更高的配置，写下去会把它连同不认识的字段一起抹掉。
    case wouldOverwriteNewerSchema(found: Int, supported: Int)
}

/// 配置文件的读写。
///
/// 一个方案一个 JSON 文件，直接放在 Application Support 的 AppBox 目录下，
/// 与图标缓存的 `icons/` 子目录平级，两者物理分离（ADR-0005）。
public struct AppBoxConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 方案名到文件路径的映射。
    ///
    /// 方案名来自用户输入，而它会成为路径的一段，所以在这里挡掉分隔符与隐藏文件。
    public func profileURL(named name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("."),
              trimmed != ".." else {
            throw ConfigStoreError.invalidProfileName(name)
        }
        return directory.appendingPathComponent("\(trimmed).json")
    }

    public func load(profile name: String = AppBoxConfig.defaultProfileName) throws -> ConfigLoadOutcome {
        let url = try profileURL(named: name)

        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .createdDefault(AppBoxConfig())
        }

        do {
            return .loaded(try decode(data))
        } catch let failure as SchemaFailure {
            switch failure {
            case .unsupportedVersion(let version):
                return .refusedUnsupportedSchema(
                    found: version,
                    supported: AppBoxConfig.currentSchemaVersion
                )
            case .malformed:
                let backup = try backUp(url)
                return .recoveredFromCorruption(AppBoxConfig(), backup: backup)
            }
        }
    }

    /// 原子写入：先写临时文件再 rename，进程中途被杀不会留下半截文件。
    /// `Data.write(options: .atomic)` 走的就是这条路，临时文件落在同一目录，
    /// 因此 rename 不会跨卷。
    ///
    /// 写之前会看一眼磁盘上那份的版本：比当前新就拒绝。
    /// 否则「加载时拒绝高版本」只保住了一次读取，用户降级后随手改个设置就把新字段全抹了。
    public func save(_ config: AppBoxConfig, as name: String = AppBoxConfig.defaultProfileName) throws {
        let url = try profileURL(named: name)

        if let existing = FileManager.default.contents(atPath: url.path),
           let found = Self.schemaVersion(in: existing),
           found > AppBoxConfig.currentSchemaVersion {
            throw ConfigStoreError.wouldOverwriteNewerSchema(
                found: found,
                supported: AppBoxConfig.currentSchemaVersion
            )
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        // sortedKeys 让同样的配置永远编出同样的字节，文件可手改也可 diff；
        // withoutEscapingSlashes 是为了别把路径写成 `\/Applications`。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// 从原始 JSON 里取版本号。取不到就当文件不可读，交由调用方决定是降级还是拒绝。
    private static func schemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? Int
    }

    private func decode(_ data: Data) throws -> AppBoxConfig {
        // 版本号必须先于解码拿到手：`Codable` 会忽略不认识的字段，直接解码的话
        // 高版本文件能"成功"读成一个低版本配置，之后一旦回写就把新字段抹掉了。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else {
            throw SchemaFailure.malformed
        }

        guard version <= AppBoxConfig.currentSchemaVersion else {
            throw SchemaFailure.unsupportedVersion(version)
        }

        let payload = try Self.migrated(object, from: version)

        guard let migrated = try? JSONSerialization.data(withJSONObject: payload),
              let config = try? JSONDecoder().decode(AppBoxConfig.self, from: migrated) else {
            throw SchemaFailure.malformed
        }
        return config
    }

    /// schema 迁移入口。
    ///
    /// 现在还没有历史版本，所以落在当前版本之前的文件一律以 `unsupportedSchema` 拒绝，
    /// 而不是当成损坏去覆盖——版本号认不出来不等于内容坏了。
    ///
    /// 第一次改字段时把 `currentSchemaVersion` +1，并在这里逐级升（1→2→3），
    /// 每段迁移只关心自己那一档的变化，升完把 `schemaVersion` 改写成下一档。
    private static func migrated(_ payload: [String: Any], from version: Int) throws -> [String: Any] {
        guard version == AppBoxConfig.currentSchemaVersion else {
            throw SchemaFailure.unsupportedVersion(version)
        }
        return payload
    }

    /// 把读不出来的文件改名保底。带时间戳且不覆盖同名备份，
    /// 所以连续两次损坏不会让前一次的现场消失。
    private func backUp(_ url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())

        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)-\(suffix).\(ext)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }

    private enum SchemaFailure: Error {
        case malformed
        case unsupportedVersion(Int)
    }
}
