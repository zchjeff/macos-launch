import Foundation

/// 一次工具计算的预算。
///
/// 每个工具按自己的风险声明预算：纯文本搬运可以放宽，带回溯风险的要收窄。
public struct ToolBudget: Hashable, Sendable {
    /// 输入字符数上限，超过直接拒绝，不起任务。
    public let inputLimit: Int
    /// 墙钟超时（秒）。
    public let timeout: TimeInterval

    public init(inputLimit: Int, timeout: TimeInterval) {
        self.inputLimit = inputLimit
        self.timeout = timeout
    }

    /// 常规文本工具：长度放宽，超时给足。
    public static let standard = ToolBudget(inputLimit: 500_000, timeout: 5)

    /// 可能指数级回溯的工具（正则）。输入收窄、超时收紧。
    public static let backtracking = ToolBudget(inputLimit: 10_000, timeout: 2)
}

/// 工具计算的失败。
///
/// 工具自身的错误（如 JSON 语法错误）原样抛出，不套在这个枚举里——
/// 那些错误各工具自己会说人话，包一层只会把有信息的错误压成一句泛泛的话。
public enum ToolFailure: Error, Equatable, Sendable {
    case inputTooLong(limit: Int, actual: Int)
    case timedOut(seconds: TimeInterval)

    public var localizedDescription: String {
        switch self {
        case .inputTooLong(let limit, let actual):
            "输入过长：\(actual) 个字符，上限 \(limit) 个。"
        case .timedOut(let seconds):
            "计算超时（超过 \(Int(seconds)) 秒）：这个输入让计算量爆炸了，已放弃等待。"
        }
    }
}

/// 在后台跑一次工具计算，带预算与超时。
///
/// ## 主线程永不跑工具逻辑
/// 计算一律丢到后台队列，主线程只接结果。任何输入都不该让界面失去响应。
///
/// ## 「取消」的诚实定义
/// 这里的超时是**放弃等待，不是中断**。
///
/// 原因：`NSRegularExpression` 一旦进入指数级回溯就在 C 层阻塞，既没有步数上限，
/// 也无法从外部打断。所以到点之后，那个后台线程会**继续跑完**——我们只是不再等它、
/// 也不再把它后来的结果当回事。能保住的底线是「界面不冻结」，不是「CPU 不浪费」。
///
/// 也正因为如此，实现**刻意避开** `withTaskGroup`：任务组在作用域退出时会等待所有
/// 子任务，那个卡住的任务会把整个函数拖住，超时形同虚设。这里用非结构化的
/// GCD 作业 + 一次性闸门，超时才真的能兑现。
public enum ToolWork {
    public static func run<Output: Sendable>(
        _ budget: ToolBudget,
        input: String,
        operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        guard input.count <= budget.inputLimit else {
            throw ToolFailure.inputTooLong(limit: budget.inputLimit, actual: input.count)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumptionGate(continuation: continuation)
            let queue = DispatchQueue.global(qos: .userInitiated)

            // 到点即作废这次等待。若计算早已完成，闸门会忽略这次。
            queue.asyncAfter(deadline: .now() + budget.timeout) {
                gate.fail(ToolFailure.timedOut(seconds: budget.timeout))
            }

            queue.async {
                do {
                    gate.succeed(try operation())
                } catch {
                    gate.fail(error)
                }
            }
        }
    }
}

/// 只允许兑现一次的结果闸门。
///
/// 超时与完成是两个独立的异步事件，谁先到都合法，第二个必须被丢弃——
/// 重复 resume 一个 continuation 会直接崩溃。
private final class ResumptionGate<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false
    private let continuation: CheckedContinuation<Output, any Error>

    init(continuation: CheckedContinuation<Output, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Output) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSettled else { return }
        isSettled = true
        continuation.resume(returning: value)
    }

    func fail(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSettled else { return }
        isSettled = true
        continuation.resume(throwing: error)
    }
}
