import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// 控制台里拖动一个应用时携带的类型。
    ///
    /// 只在本进程内用，但还是在 Info.plist 里声明了（见 `scripts/build-app.sh`），
    /// 否则系统会在第一次拖拽时抱怨这是个没声明过的类型。
    static let appBoxApplication = UTType(
        exportedAs: "com.ethicall.appbox.application",
        conformingTo: .data
    )
}

/// 应用在拖拽中传递的载荷。
///
/// 用独立的类型而不是裸 `String`：侧栏的分组行既要接受「把应用拖进来」，
/// 自己又要能被拖动排序。两种拖拽若共用一种载荷就分不开了——
/// 拖分组的时候会被当成往组里放应用。
struct ApplicationDragPayload: Codable, Transferable {
    let bundleIdentifier: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .appBoxApplication)
    }
}
