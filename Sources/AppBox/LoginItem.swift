import AppBoxCore
import Foundation
import ServiceManagement

/// 用 `SMAppService` 管理开机启动注册。
///
/// 只认 `.app` 外壳里的主程序：从 SwiftPM 裸可执行文件注册没有意义（登录项会指向
/// 构建产物），此时 `register()` 抛错，开关会弹系统给的说法。
struct SMAppServiceLoginItemController: LoginItemControlling {
    var status: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
