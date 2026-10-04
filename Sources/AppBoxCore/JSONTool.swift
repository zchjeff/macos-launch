import Foundation

/// JSON 的文本级格式化与压缩。
///
/// 刻意**不经过** `JSONSerialization`。那条路把对象装进 `NSDictionary`，于是：
/// 键序被重排成哈希序（不是原序、也不是字母序）、`/` 被转义成 `\/`，
/// 超过约 40 位的整数与 `0.1` 这类浮点还会改变字面量——那已经不是「排整齐」，
/// 而是「换了份数据」。本工具的首要职责是前者，所以只重排空白，其余字符原样搬运。
///
/// 代价是得自己承担语法校验：非法输入必须在**写出任何东西之前**被拒绝，
/// 否则会产出「看起来格式化过了、其实已经不是合法 JSON」的文本。
///
/// 错误定位不借用 `JSONSerialization` 的英文报错文本（那是自由格式，无保证），
/// 由扫描器自己记录位置，报出来的行列号与用户看到的字符一一对应。
public enum JSONTool {
    /// 嵌套深度上限。
    ///
    /// 递归下降解析器是**按嵌套层数消耗调用栈**的，而调用栈有硬上限。
    /// 一份粘贴进来的深层 JSON（生成的 mock、日志里的巨型对象）不该有本事让 AppBox 崩溃，
    /// 所以这里设一道闸门：超限就报错，报错可恢复，崩溃不可恢复。
    ///
    /// ## 这个数字是怎么定的
    /// 关键在于**栈有多大**，而工具计算跑在 `ToolWork` 的 `DispatchQueue.global` 上——
    /// 那里线程栈实测只有 **524 KB**，不是主线程的 8 MB。在同一份代码上实测：
    ///
    /// | 执行上下文 | 安全深度 |
    /// |---|---|
    /// | 主线程（≈8 MB 栈） | 500 层通过 |
    /// | `DispatchQueue.global`（≈512 KB 栈） | 120 层存活，**140 层崩溃** |
    ///
    /// 一版实现曾按「主线程 1000 层通过」把上限设成 500，那等于在真实执行路径上
    /// 提前 4 倍越界——用户粘贴一份深层 JSON 就能把进程打崩，而 guard 根本来不及生效。
    /// 现在的 100 是按 `DispatchQueue.global` 的实测值再留余量定的。
    ///
    /// 真实配置文件与 API 响应通常不到 20 层，100 层对合法输入没有误伤。
    /// 上限若还要抬高，得先证明所有执行路径的栈都够用，而不是只看主线程。
    public static let maximumDepth = 100

    /// 缩进单位。
    public enum Indent: Hashable, Sendable {
        case spaces(Int)
        case tab

        var unit: String {
            switch self {
            case .spaces(let count): String(repeating: " ", count: max(0, count))
            case .tab: "\t"
            }
        }
    }

    /// 拒绝输入的原因。`line` / `column` 都从 1 起算，指向出问题的那个字符。
    public struct Failure: Error, Equatable, Sendable {
        public let line: Int
        public let column: Int
        public let message: String

        public init(line: Int, column: Int, message: String) {
            self.line = line
            self.column = column
            self.message = message
        }

        /// 给界面用的一句话：位置放前面，用户可以直接照着去定位。
        public var localizedDescription: String {
            "第 \(line) 行第 \(column) 列：\(message)"
        }
    }

    /// 重排空白。
    ///
    /// - Parameters:
    ///   - text: 待处理的 JSON 文本，顶层允许是任意值（不限于对象/数组）。
    ///   - indent: 缩进单位，`compact` 为真时不起作用。
    ///   - compact: 压成单行，token 之间只保留语法必需的部分。
    public static func reformat(
        _ text: String,
        indent: Indent = .spaces(2),
        compact: Bool = false
    ) throws(Failure) -> String {
        var scanner = JSONScanner(text: text, indent: indent, compact: compact)
        return try scanner.run()
    }
}

/// JSON 文本的扫描与重排。
///
/// 一次线性扫描同时做三件事：校验语法、记录位置、把空白按目标格式重新写出。
/// 拆成「先校验再格式化」要扫两遍，而校验与重排本来就共享同一份状态机。
private struct JSONScanner {
    private let characters: [Character]
    private let indentUnit: String
    private let compact: Bool

    private var cursor = 0
    private var line = 1
    private var column = 1
    private var output = ""

    init(text: String, indent: JSONTool.Indent, compact: Bool) {
        characters = Array(text)
        indentUnit = indent.unit
        self.compact = compact
    }

    mutating func run() throws(JSONTool.Failure) -> String {
        // 开头的字节顺序标记直接吃掉。
        //
        // U+FEFF 不是 JSON 的一部分（RFC 8259 明确说不得添加），但真实世界到处都有：
        // 从 Windows 环境、某些 API、某些编辑器来的文本常带它，`JSONSerialization`
        // 也照样接受。把它当成语法错误会拦下一份本来完全合法的 JSON。
        // 只处理**开头**这一个：中间出现的 U+FEFF 属于字符串内容，不能动。
        if peek() == "\u{FEFF}" {
            advance()
        }

        skipWhitespace()
        guard peek() != nil else {
            throw failure("输入为空")
        }
        try parseValue(depth: 0)
        skipWhitespace()
        if let extra = peek() {
            throw failure("这里多出了「\(extra)」：一个 JSON 文本只能有一个顶层值")
        }
        return output
    }

    // MARK: - 值

    private mutating func parseValue(depth: Int) throws(JSONTool.Failure) {
        guard depth <= JSONTool.maximumDepth else {
            throw failure("嵌套太深（超过 \(JSONTool.maximumDepth) 层）：这样的输入会让解析器耗尽调用栈")
        }
        guard let character = peek() else {
            throw failure("这里需要一个值，但输入已经结束")
        }
        switch character {
        case "{": try parseObject(depth: depth)
        case "[": try parseArray(depth: depth)
        case "\"": try parseString()
        case "t", "f", "n": try parseLiteral()
        case "-", "0"..."9": try parseNumber()
        default: throw failure("这里需要一个值，但遇到了「\(character)」")
        }
    }

    private mutating func parseObject(depth: Int) throws(JSONTool.Failure) {
        emit("{")
        advance()
        skipWhitespace()
        if peek() == "}" {
            emit("}")
            advance()
            return
        }
        breakLine(depth: depth + 1)

        while true {
            if peek() == "," {
                throw failure("这里多了一个逗号")
            }
            guard peek() == "\"" else {
                throw peek() == nil
                    ? failure("对象没有闭合的 }")
                    : failure("对象的键必须是双引号字符串")
            }
            try parseString()
            skipWhitespace()

            guard peek() == ":" else {
                throw failure("键之后缺少 :")
            }
            emit(":")
            advance()
            skipWhitespace()
            if !compact { emit(" ") }

            try parseValue(depth: depth + 1)
            skipWhitespace()

            switch peek() {
            case ",":
                emit(",")
                advance()
                skipWhitespace()
                if peek() == "}" {
                    throw failure("这里多了一个逗号：JSON 不允许尾随逗号")
                }
                breakLine(depth: depth + 1)
            case "}":
                if !compact { breakLine(depth: depth) }
                emit("}")
                advance()
                return
            case nil:
                throw failure("对象没有闭合的 }")
            default:
                throw failure("对象里缺一个 , 或 }")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(JSONTool.Failure) {
        emit("[")
        advance()
        skipWhitespace()
        if peek() == "]" {
            emit("]")
            advance()
            return
        }
        breakLine(depth: depth + 1)

        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()

            switch peek() {
            case ",":
                emit(",")
                advance()
                skipWhitespace()
                if peek() == "]" {
                    throw failure("这里多了一个逗号：JSON 不允许尾随逗号")
                }
                breakLine(depth: depth + 1)
            case "]":
                if !compact { breakLine(depth: depth) }
                emit("]")
                advance()
                return
            case nil:
                throw failure("数组没有闭合的 ]")
            default:
                throw failure("数组里缺一个 , 或 ]")
            }
        }
    }

    /// 字符串：逐字符搬运，转义序列**原样保留**（`\u4e2d` 不还原成汉字）。
    ///
    /// 还原再重编码会改变字面量——`"\/"` 与 `"/"` 是同一个值的两种写法，
    /// 但用户拿到的东西必须跟他给的一样。
    private mutating func parseString() throws(JSONTool.Failure) {
        emit("\"")
        advance()

        while true {
            guard let character = peek() else {
                throw failure("字符串没有闭合的 \"")
            }
            if character == "\"" {
                emit("\"")
                advance()
                return
            }
            if character == "\\" {
                emit("\\")
                advance()
                guard let escape = peek() else {
                    throw failure("转义符 \\ 之后没有字符")
                }
                switch escape {
                case "\"", "\\", "/", "b", "f", "n", "r", "t":
                    emit(String(escape))
                    advance()
                case "u":
                    emit("u")
                    advance()
                    for _ in 0..<4 {
                        guard let hex = peek(), isHexDigit(hex) else {
                            throw failure("\\u 之后需要 4 位十六进制数字")
                        }
                        emit(String(hex))
                        advance()
                    }
                default:
                    throw failure("不是合法的转义：\\\(escape)")
                }
                continue
            }
            if isControlCharacter(character) {
                throw failure("字符串里有一个未转义的控制字符")
            }
            emit(String(character))
            advance()
        }
    }

    /// 数字：**严格按 JSON 文法**校验，但字面量原样搬运，不做数值转换。
    ///
    /// 不经过 `Double` 是刻意的：那样 44 位整数会被改写、`0.1` 会变成
    /// `0.10000000000000001`。这里只判断"它是不是一个合法的 JSON 数字"。
    private mutating func parseNumber() throws(JSONTool.Failure) {
        if peek() == "-" {
            emit("-")
            advance()
        }
        guard let first = peek() else {
            throw failure("输入以不完整的数字结束")
        }

        if first == "0" {
            emit("0")
            advance()
            if let next = peek(), isDigit(next) {
                throw failure("数字不能有前导零")
            }
        } else if isDigit(first) {
            while let digit = peek(), isDigit(digit) {
                emit(String(digit))
                advance()
            }
        } else {
            throw failure("这里需要一个数字，但遇到了「\(first)」")
        }

        if peek() == "." {
            emit(".")
            advance()
            guard let digit = peek(), isDigit(digit) else {
                throw failure("小数点后面需要数字")
            }
            while let digit = peek(), isDigit(digit) {
                emit(String(digit))
                advance()
            }
        }

        if peek() == "e" || peek() == "E" {
            emit(String(peek()!))
            advance()
            if peek() == "+" || peek() == "-" {
                emit(String(peek()!))
                advance()
            }
            guard let digit = peek(), isDigit(digit) else {
                throw failure("指数部分需要数字")
            }
            while let digit = peek(), isDigit(digit) {
                emit(String(digit))
                advance()
            }
        }
    }

    private mutating func parseLiteral() throws(JSONTool.Failure) {
        switch peek() {
        case "t": try expect("true")
        case "f": try expect("false")
        default: try expect("null")
        }
    }

    private mutating func expect(_ literal: String) throws(JSONTool.Failure) {
        for character in literal {
            guard peek() == character else {
                throw failure("这里应当是 \(literal)")
            }
            emit(String(character))
            advance()
        }
    }

    // MARK: - 位置与输出

    private mutating func skipWhitespace() {
        while let character = peek(), isJSONWhitespace(character) {
            advance()
        }
    }

    /// 是否是 JSON 允许的空白：空格、制表符、换行、回车。
    ///
    /// 用 `unicodeScalars` 而不是直接比较 `Character`：Swift 的 `Character` 是
    /// **grapheme cluster**，`"\r\n"` 是**单个** `Character`，既不等于 `"\r"`
    /// 也不等于 `"\n"`。直接比较会漏掉它，于是从 Windows 环境拷来的 CRLF 文本
    /// 会被报成语法错误——那正是最需要能直接用的输入。
    private func isJSONWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
        }
    }

    private func isLineBreak(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    private mutating func breakLine(depth: Int) {
        guard !compact else { return }
        emit("\n")
        for _ in 0..<depth {
            emit(indentUnit)
        }
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let index = cursor + offset
        return index < characters.count ? characters[index] : nil
    }

    private mutating func advance() {
        guard cursor < characters.count else { return }
        // 用 `isLineBreak` 而不是比较 `"\n"`：CRLF 是**单个** Character，
        // 直接比较会漏掉它，行号从此不再增长，后面所有报错都会指错行。
        if isLineBreak(characters[cursor]) {
            line += 1
            column = 1
        } else {
            column += 1
        }
        cursor += 1
    }

    private mutating func emit(_ text: String) {
        output.append(contentsOf: text)
    }

    private func failure(_ message: String) -> JSONTool.Failure {
        JSONTool.Failure(line: line, column: column, message: message)
    }

    /// 只认 ASCII 数字：`Character.isNumber` 会把全角「１」与阿拉伯-印度数字也判为真，
    /// 而那些字符在 JSON 里根本不合法。
    private func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private func isHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }

    private func isControlCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value < 0x20 }
    }
}
