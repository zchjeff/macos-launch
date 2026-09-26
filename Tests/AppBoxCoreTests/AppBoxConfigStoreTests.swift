import Foundation
import Testing

@testable import AppBoxCore

/// 真实临时目录里的配置文件读写。用真文件系统而不是内存实现：
/// 原子性、改名备份、目录自动创建这些正是要验证的行为，mock 掉就等于没测。
@Suite("配置持久化")
struct AppBoxConfigStoreTests {
    private func makeStore() throws -> (store: AppBoxConfigStore, directory: URL, cleanup: TempDirectory) {
        let cleanup = try TempDirectory()
        return (AppBoxConfigStore(directory: cleanup.url), cleanup.url, cleanup)
    }

    @Test("文件不存在时给默认配置，且不落盘")
    func defaultsWhenNoFile() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let outcome = try store.load()
        #expect(outcome == .createdDefault(AppBoxConfig()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("保存后配置文件出现在指定目录，内容是带 schemaVersion 的 JSON")
    func savesReadableJSON() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig())

        let url = directory.appendingPathComponent("default.json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("\(AppBoxConfig.currentSchemaVersion)"))
    }

    @Test("编码 → 解码 → 再编码，字节完全一致")
    func roundTripIsIdempotent() throws {
        let (store, _, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig())
        let url = try store.profileURL(named: AppBoxConfig.defaultProfileName)
        let first = try Data(contentsOf: url)

        guard case .loaded(let decoded) = try store.load() else {
            Issue.record("应当读出配置")
            return
        }
        try store.save(decoded)
        #expect(try Data(contentsOf: url) == first)
    }

    @Test("读回来的配置与写进去的相等")
    func loadedConfigMatchesSaved() throws {
        let (store, _, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig())
        #expect(try store.load() == .loaded(AppBoxConfig()))
    }

    @Test("高版本配置被拒绝加载，且原文件一个字节都不动")
    func refusesNewerSchema() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let url = directory.appendingPathComponent("default.json")
        let newer = """
        {
          "schemaVersion" : 99,
          "futureField" : "未来版本才有的内容"
        }
        """
        try Data(newer.utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let outcome = try store.load()
        #expect(outcome == .refusedUnsupportedSchema(found: 99, supported: AppBoxConfig.currentSchemaVersion))
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["default.json"])
    }

    @Test("低版本配置没有迁移路径时被拒绝，不当作损坏去覆盖")
    func refusesOlderSchemaWithoutMigration() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let url = directory.appendingPathComponent("default.json")
        try Data(#"{"schemaVersion" : 0}"#.utf8).write(to: url)
        let before = try Data(contentsOf: url)

        #expect(try store.load() == .refusedUnsupportedSchema(found: 0, supported: AppBoxConfig.currentSchemaVersion))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("保存时发现磁盘上那份版本更高就拒绝写入，不抹掉不认识的字段")
    func refusesToOverwriteNewerSchema() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let url = directory.appendingPathComponent("default.json")
        let newer = """
        {
          "schemaVersion" : 99,
          "futureField" : "未来版本才有的内容"
        }
        """
        try Data(newer.utf8).write(to: url)
        let before = try Data(contentsOf: url)

        // 只有加载被拒绝是不够的：用户降级后随手改个设置，写下去照样把新字段抹平。
        #expect(throws: ConfigStoreError.wouldOverwriteNewerSchema(found: 99, supported: AppBoxConfig.currentSchemaVersion)) {
            try store.save(AppBoxConfig())
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("没有配置文件或版本不高于当前时，正常写入")
    func allowsNormalSaves() throws {
        let (store, _, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig())
        try store.save(AppBoxConfig())
        #expect(try store.load() == .loaded(AppBoxConfig()))
    }

    @Test("损坏的 JSON 降级为默认配置，原文件改名备份且内容保留")
    func recoversFromCorruption() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let url = directory.appendingPathComponent("default.json")
        let broken = "{ 这不是 JSON"
        try Data(broken.utf8).write(to: url)

        let outcome = try store.load()
        guard case .recoveredFromCorruption(let config, let backup) = outcome else {
            Issue.record("应当走损坏降级，实际是 \(outcome)")
            return
        }

        #expect(config == AppBoxConfig())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: backup) == Data(broken.utf8))
    }

    @Test("缺 schemaVersion 字段的文件按损坏处理")
    func treatsMissingVersionAsCorruption() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try Data(#"{"groups" : []}"#.utf8).write(to: directory.appendingPathComponent("default.json"))

        guard case .recoveredFromCorruption = try store.load() else {
            Issue.record("缺少版本号应当按损坏处理")
            return
        }
    }

    @Test("连续两次损坏各自留下备份，不互相覆盖")
    func corruptionBackupsDoNotOverwrite() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        let url = directory.appendingPathComponent("default.json")
        try Data("{ 第一次坏".utf8).write(to: url)
        guard case .recoveredFromCorruption(_, let firstBackup) = try store.load() else {
            Issue.record("第一次应当走损坏降级")
            return
        }

        try Data("{ 第二次坏".utf8).write(to: url)
        guard case .recoveredFromCorruption(_, let secondBackup) = try store.load() else {
            Issue.record("第二次应当走损坏降级")
            return
        }

        #expect(firstBackup != secondBackup)
        #expect(try Data(contentsOf: firstBackup) == Data("{ 第一次坏".utf8))
        #expect(try Data(contentsOf: secondBackup) == Data("{ 第二次坏".utf8))
    }

    @Test("保存后目录里只有目标文件，没有临时文件残留")
    func saveLeavesNoTemporaryFiles() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig())
        try store.save(AppBoxConfig())

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["default.json"])
    }

    @Test("目录不存在时保存会自动建出目录")
    func createsDirectoryOnSave() throws {
        let cleanup = try TempDirectory()
        defer { withExtendedLifetime(cleanup) {} }

        let nested = cleanup.url.appendingPathComponent("AppBox", isDirectory: true)
        let store = AppBoxConfigStore(directory: nested)
        try store.save(AppBoxConfig())

        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("default.json").path))
    }

    @Test("一个方案一个文件，各方案互不覆盖")
    func profilesAreSeparateFiles() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        try store.save(AppBoxConfig(), as: "default")
        try store.save(AppBoxConfig(), as: "工作")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["default.json", "工作.json"])
        #expect(try store.load(profile: "工作") == .loaded(AppBoxConfig()))
    }

    @Test("方案名不能当文件名用的一律拒绝", arguments: ["", "   ", "a/b", "..", ".hidden", "a\\b"])
    func rejectsUnsafeProfileNames(name: String) throws {
        let (store, _, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        #expect(throws: ConfigStoreError.invalidProfileName(name)) {
            try store.profileURL(named: name)
        }
    }

    @Test("方案名首尾空白被裁掉")
    func trimsProfileName() throws {
        let (store, directory, cleanup) = try makeStore()
        defer { withExtendedLifetime(cleanup) {} }

        #expect(try store.profileURL(named: " 工作 ") == directory.appendingPathComponent("工作.json"))
    }
}

/// 用完即删的临时目录。
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppBoxConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
