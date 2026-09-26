import AppBoxCore
import Foundation
import Testing

@Test("AppBoxCore 能被链接，且身份常量与打包脚本约定一致")
func identityConstantsMatchPackagingContract() {
    #expect(AppBoxIdentity.bundleIdentifier == "com.ethicall.appbox")
    #expect(AppBoxIdentity.displayName == "AppBox")
}

@Test("配置目录落在 Application Support 下的 AppBox 子目录")
func applicationSupportDirectoryIsUnderAppBox() {
    let directory = AppBoxIdentity.applicationSupportDirectory
    #expect(directory.lastPathComponent == "AppBox")
    #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
}

@Test("图标缓存是配置目录的子文件夹，与配置文件物理分离")
func iconsLiveInTheirOwnSubdirectory() throws {
    let support = AppBoxIdentity.applicationSupportDirectory
    #expect(AppBoxIdentity.iconsDirectory.deletingLastPathComponent() == support)

    // 配置文件直接躺在 AppBox 目录下，与 icons/ 平级而不是被塞进去。
    let store = AppBoxConfigStore(directory: support)
    let config = try store.profileURL(named: AppBoxConfig.defaultProfileName)
    #expect(config.deletingLastPathComponent() == support)
    #expect(config.pathExtension == "json")
}
