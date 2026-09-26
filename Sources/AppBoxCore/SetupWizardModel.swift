import Foundation
import Observation

/// 引导整理的视图模型。
///
/// 放在领域层是为了可测：向导真正的新东西是「改一条、并两条、删一条之后，
/// 最后会写出什么样的配置」，这部分不该只能靠手点界面来验证。
///
/// 它在确认之前**不碰磁盘**——用户在向导里的每一次增删改都只动内存里的建议。
/// 「用户确认后才写入配置」这条因此不是靠小心，是靠没有第二条写盘路径。
@MainActor
@Observable
public final class SetupWizardModel {
    /// 当前的建议，顺序即界面顺序。
    public private(set) var suggestions: [SetupSuggestion]
    /// 被跳过的建议。跳过是「这次先不采纳」，不是「这条建议错了」——
    /// 所以它留在列表里，随时可以恢复。与删除的区别就在这里。
    public private(set) var skippedIDs: Set<String> = []
    /// 表里没认出来的类别值，界面拿它说明一句「这些先留在未分类」。
    public let unrecognizedCategories: [String]
    /// 最近一次失败的说法。
    public private(set) var errorMessage: String?

    private let service: LibraryService
    /// 这次整理涉及的全部应用：建议里的加上没建议的。
    /// 「留在未分类的有多少」永远是它减去被采纳的那些，删一条、跳过一条都会跟着动。
    private let allApplications: [ApplicationEntry]

    public init(service: LibraryService, plan: SetupPlan) {
        self.service = service
        self.suggestions = plan.suggestions
        self.unrecognizedCategories = plan.unrecognizedCategories
        self.allApplications = (plan.suggestions.flatMap(\.applications) + plan.unassigned)
            .sorted(by: SetupAdvisor.precedes)
    }

    // MARK: - 读

    /// 这次会被采纳的建议。
    public var accepted: [SetupSuggestion] {
        suggestions.filter { !skippedIDs.contains($0.id) }
    }

    public var acceptedCount: Int { accepted.count }

    /// 采纳的建议一共覆盖多少个应用。
    public var assignedCount: Int { accepted.reduce(0) { $0 + $1.applications.count } }

    public var totalCount: Int { allApplications.count }

    /// 确认之后会留在「未分类」的应用数量。
    ///
    /// 直接相减是成立的：一条建议对应一个类别，一个应用只有一个类别，
    /// 所以各条建议名下的应用互不重叠，数量之和就是并集大小。
    public var unclassifiedCount: Int { totalCount - assignedCount }

    public func isSkipped(_ id: String) -> Bool { skippedIDs.contains(id) }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - 改

    /// 改名。首尾空白去掉；空名、与别的建议重名都会被拒绝——拒绝之后名字不变，
    /// 界面照旧显示原来的名字，同时给出一句说法。
    public func rename(_ id: String, to name: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = GroupError.emptyName.localizedDescription
            return
        }
        // 重名不自动合并：用户想合成一组时该用「并入」，否则他只会看到一条少了的建议。
        guard !suggestions.contains(where: { $0.id != id && $0.name == trimmed }) else {
            errorMessage = "已经有叫「\(trimmed)」的建议了；想合成一组请用「并入」"
            return
        }

        suggestions[index].name = trimmed
        errorMessage = nil
    }

    /// 把一条建议并进另一条：成员跟过去，源那一条就此消失。
    public func merge(_ id: String, into targetID: String) {
        guard id != targetID,
              let source = suggestions.firstIndex(where: { $0.id == id }),
              let target = suggestions.firstIndex(where: { $0.id == targetID }) else { return }

        suggestions[target].applications = (suggestions[target].applications + suggestions[source].applications)
            .sorted(by: SetupAdvisor.precedes)
        // 顺序要紧：先写目标再移除源，否则源在前时下标就串了。
        suggestions.remove(at: source)
        skippedIDs.remove(id)
        errorMessage = nil
    }

    /// 删掉一条建议：它名下的应用回到「未分类」。
    ///
    /// 不弹确认框：向导里的每一次点击都还没落盘，整件事随时可以「取消」重来，
    /// 为一次可逆的内存操作弹窗，比不弹更烦人。
    public func remove(_ id: String) {
        suggestions.removeAll { $0.id == id }
        skippedIDs.remove(id)
        errorMessage = nil
    }

    /// 跳过：这次不采纳，但建议留着。与删除的区别是这条建议还在列表里。
    /// 对配置的效果与删除一样——都不建这个组，应用留在「未分类」。
    public func skip(_ id: String) {
        guard suggestions.contains(where: { $0.id == id }) else { return }
        skippedIDs.insert(id)
        errorMessage = nil
    }

    public func restore(_ id: String) {
        skippedIDs.remove(id)
        errorMessage = nil
    }

    // MARK: - 写

    /// 采纳当前的建议：一次写盘建好全部分组。返回是否写成功。
    public func confirm() async -> Bool {
        await write(accepted.map {
            GroupPlan(name: $0.name, members: $0.applications.map(\.bundleIdentifier))
        })
    }

    /// 取消：采纳一个空计划——配置落成初始状态（只有「未分类」，应用都在其中），
    /// 同时让「首次启动」这件事过去，向导不会下次又冒出来。
    public func cancel() async -> Bool {
        await write([])
    }

    private func write(_ groups: [GroupPlan]) async -> Bool {
        let service = self.service
        do {
            try await Task.detached(priority: .userInitiated) {
                try service.applySetup(groups)
            }.value
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
