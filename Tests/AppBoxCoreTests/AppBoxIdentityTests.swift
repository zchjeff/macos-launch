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
