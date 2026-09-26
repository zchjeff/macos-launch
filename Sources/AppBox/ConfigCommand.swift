import AppBoxCore
import Foundation

/// `AppBox --config`：打印配置目录、方案文件与加载结果，首次运行时落一份默认配置。
///
/// 这个切片的配置项还是空的，所以没有界面可看——持久化是否真的工作只能靠这里看。
enum ConfigCommand {
    static func run() {
        let directory = AppBoxIdentity.applicationSupportDirectory
        let store = AppBoxConfigStore(directory: directory)

        print("配置目录：\(directory.path)")
        print("方案文件：\((try? store.profileURL(named: AppBoxConfig.defaultProfileName))?.path ?? "—")")
        print("图标缓存：\(AppBoxIdentity.iconsDirectory.path)")
        print("当前 schema 版本：\(AppBoxConfig.currentSchemaVersion)")
        print("")

        do {
            switch try store.load() {
            case .loaded(let config):
                print("加载结果：读到配置，schemaVersion = \(config.schemaVersion)")

            case .createdDefault(let config):
                // 只在确实没有配置文件时才写。有文件却读不出来（损坏/高版本）时这里绝不能写，
                // 否则刚打印完"拒绝加载"，转头就把人家的文件覆盖了。
                try store.save(config)
                let readBack = try store.load()
                print("加载结果：方案文件不存在（首次启动），已写入默认配置")
                print("          写入后读回：\(readBack == .loaded(config) ? "一致" : "不一致（\(readBack)）")")

            case .recoveredFromCorruption(let config, let backup):
                print("加载结果：配置文件读不出来，已降级为默认配置")
                print("          原文件备份在：\(backup.path)")
                print("          schemaVersion = \(config.schemaVersion)")

            case .refusedUnsupportedSchema(let found, let supported):
                print("加载结果：拒绝加载——文件版本 \(found)，本程序支持 \(supported)")
                print("          文件未被修改，请升级 AppBox 或手工处理该文件")
            }
        } catch {
            print("加载结果：失败——\(error)")
        }
    }
}
