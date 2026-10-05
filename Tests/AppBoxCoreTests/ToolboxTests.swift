import Foundation
import Testing

@testable import AppBoxCore

/// 跑一个必失败的调用，把抛出的错误取回来自己断言。
///
/// 刻意不用 `#expect(throws:)` 的**返回值**形式：那依赖较新的 swift-testing API，
/// 而这里真正想要的是「拿到错误、检查它的行号/列号/文案」。
/// 用这个 helper 就不必赌某个 API 版本的具体形状。
func catching<T>(_ body: () throws -> T) -> (any Error)? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

/// `catching` 的异步版本。
func catchingAsync<T: Sendable>(_ body: () async throws -> T) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

@Suite("工具箱：JSON 格式化")
struct JSONToolTests {
    // MARK: - 保真（这个工具存在的理由）

    @Test("键序完全按原文保留，不重排")
    func preservesKeyOrder() throws {
        let raw = #"{"zebra":1,"alpha":2,"mid":3}"#
        let output = try JSONTool.reformat(raw)
        let keys = output.split(separator: "\n").compactMap { line -> String? in
            guard let start = line.firstIndex(of: "\""),
                  let end = line[line.index(after: start)...].firstIndex(of: "\"") else { return nil }
            return String(line[line.index(after: start)..<end])
        }
        #expect(keys == ["zebra", "alpha", "mid"])
    }

    @Test("大整数与浮点字面量逐字节保留，不被改写成别的写法")
    func preservesNumberLiterals() throws {
        // 对照：走 `JSONSerialization` 的话，44 位整数会变成 …99000000，
        // 0.1 会变成 0.10000000000000001，1e10 会变成 10000000000。
        // 对这些输入来说，那不是「排整齐」，而是「换了份数据」。
        let raw = #"{"big":12345678901234567890123,"f":0.1,"e":1e10}"#
        let output = try JSONTool.reformat(raw)
        #expect(output.contains(#""big": 12345678901234567890123"#))
        #expect(output.contains(#""f": 0.1"#))
        #expect(output.contains(#""e": 1e10"#))
    }

    @Test("斜杠不转义，中文不转成 \\u")
    func preservesSlashAndUnicode() throws {
        let output = try JSONTool.reformat(#"{"url":"https://a.com/b","cn":"中文"}"#)
        #expect(output.contains("https://a.com/b"))
        #expect(!output.contains("\\/"))
        #expect(output.contains("中文"))
    }

    @Test("转义序列原样搬运，不还原也不重编码")
    func preservesEscapeSequences() throws {
        // `\u4e2d` 与「中」是同一个值，但用户拿到的东西必须跟他给的一样。
        let output = try JSONTool.reformat(#"{"s":"\u4e2d\/x\n\t\"q\""}"#)
        #expect(output.contains(#"\u4e2d\/x\n\t\"q\""#))
    }

    // MARK: - 排版

    @Test("缩进：2 空格 / 4 空格 / tab")
    func appliesIndent() throws {
        let source = #"{"a":{"b":1}}"#
        #expect(try JSONTool.reformat(source, indent: .spaces(2)).contains("\n  \"a\""))
        #expect(try JSONTool.reformat(source, indent: .spaces(4)).contains("\n    \"a\""))
        #expect(try JSONTool.reformat(source, indent: .tab).contains("\n\t\"a\""))
    }

    @Test("压缩成单行且不留多余空白")
    func compacts() throws {
        let output = try JSONTool.reformat(#"{"a": [1, 2], "b": {"c": 3}}"#, compact: true)
        #expect(!output.contains("\n"))
        #expect(output == #"{"a":[1,2],"b":{"c":3}}"#)
    }

    @Test("重复格式化同一个缩进是幂等的", arguments: [
        JSONTool.Indent.spaces(2), .spaces(4), .tab,
    ])
    func isIdempotent(indent: JSONTool.Indent) throws {
        let once = try JSONTool.reformat(#"{"a":{"b":[1,2]},"c":[]}"#, indent: indent)
        #expect(try JSONTool.reformat(once, indent: indent) == once)
    }

    @Test("空容器与顶层标量")
    func handlesEmptyAndScalars() throws {
        #expect(try JSONTool.reformat("{}") == "{}")
        #expect(try JSONTool.reformat("[]") == "[]")
        for scalar in ["123", "-1.5e-3", #""x""#, "true", "false", "null"] {
            #expect(try JSONTool.reformat(scalar) == scalar)
        }
    }

    @Test("重复键是合法的，两个都保留")
    func keepsDuplicateKeys() throws {
        let output = try JSONTool.reformat(#"{"a":1,"a":2}"#)
        #expect(output == "{\n  \"a\": 1,\n  \"a\": 2\n}")
    }

    // MARK: - 真实世界的输入（实测暴露过的两个缺陷）

    @Test("CRLF 与纯 CR 换行被接受，并规范成 LF")
    func acceptsCarriageReturns() throws {
        // 缺陷背景：Swift 的 `Character` 是 grapheme cluster，`"\r\n"` 是**单个** Character，
        // 既不等于 "\r" 也不等于 "\n"。早期实现直接比较字符，于是从 Windows 环境
        // 拷来的 JSON 会被报成语法错误——而那正是最需要能直接用的输入。
        #expect(try JSONTool.reformat("{\r\n\"a\":1\r\n}") == "{\n  \"a\": 1\n}")
        #expect(try JSONTool.reformat("{\r\"a\":1\r}") == "{\n  \"a\": 1\n}")
    }

    @Test("CRLF 下报错行号仍然准确")
    func countsLinesAcrossCarriageReturns() throws {
        // 缺陷背景：`advance()` 早期只认 "\n"，遇到 CRLF 这个单 Character 时行号永不增长，
        // 于是后面所有报错都会指向第 1 行。
        let error = catching { try JSONTool.reformat("{\r\n\"a\":1,\r\n\"b\":}\r\n}") } as? JSONTool.Failure
        #expect(error?.line == 3)
    }

    @Test("开头的 BOM 被吃掉")
    func skipsByteOrderMark() throws {
        #expect(try JSONTool.reformat("\u{FEFF}{\"a\":1}") == "{\n  \"a\": 1\n}")
        #expect(try JSONTool.reformat("\u{FEFF}{\"k\":\"中文\"}").contains("中文"))
    }

    @Test("深嵌套报错而不是让进程崩溃")
    func rejectsDeepNestingInsteadOfCrashing() throws {
        // 缺陷背景：递归下降按嵌套层数消耗调用栈。一份粘贴进来的深层 JSON
        // 能把整个 AppBox 崩掉。上限把「不可恢复的崩溃」变成「可恢复的报错」。
        let depth = JSONTool.maximumDepth + 2
        let error = catching {
            try JSONTool.reformat(String(repeating: "[", count: depth) + String(repeating: "]", count: depth))
        } as? JSONTool.Failure
        #expect(error?.message.contains("嵌套太深") == true)
    }

    @Test("深嵌套上限不误伤合法输入")
    func allowsNestingUpToTheLimit() throws {
        // N 层数组最深的 parseValue 是 depth = N-1，所以报错从 maximumDepth+2 层开始。
        let allowed = JSONTool.maximumDepth + 1
        #expect((try? JSONTool.reformat(String(repeating: "[", count: allowed) + String(repeating: "]", count: allowed))) != nil)
        #expect((try? JSONTool.reformat(String(repeating: "[", count: 20) + String(repeating: "]", count: 20))) != nil)
    }

    @Test("在真实执行路径（DispatchQueue.global）上，上限之内不崩溃")
    func survivesTheDepthLimitOnTheGlobalQueue() async {
        // 这条回归测试盯的是一个**曾经真实存在**的缺陷：
        // `maximumDepth` 一开始按「主线程 1000 层通过」标定成 500，
        // 但工具计算实际跑在 `ToolWork` 的 `DispatchQueue.global` 上——
        // 那里线程栈实测只有 524 KB（主线程是 8 MB），140 层就崩。
        // 于是 500 这个上限在真实路径上提前 4 倍越界，guard 根本来不及生效。
        //
        // 所以这里必须在**真实的 global 队列**上测，而不是在主线程上测：
        // 主线程测出来的「通过」正是当初给出错误上限的原因。
        let depth = JSONTool.maximumDepth + 1
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // 能走到这里就说明没崩；崩了的话进程直接死，测试根本不会往下走。
                _ = try? JSONTool.reformat(text, compact: true)
                continuation.resume(returning: true)
            }
        }
        #expect(outcome, "在 global 队列上解析接近上限的输入时进程仍然存活")
    }

    // MARK: - 错误定位

    @Test("语法错误：位置指向出问题的那个字符")
    func reportsErrorPositions() {
        let cases: [(text: String, line: Int, column: Int, label: String)] = [
            ("", 1, 1, "空输入"),
            ("{\n  \"a\": 1,\n  \"b\": }\n}", 3, 8, "对象里缺值"),
            (#"{"a": 01}"#, 1, 8, "数字前导零"),
            ("[1,2,]", 1, 6, "数组尾随逗号"),
            (#"{"a":1,}"#, 1, 8, "对象尾随逗号"),
            ("{'a':1}", 1, 2, "单引号字符串"),
            (#"{"a" 1}"#, 1, 6, "缺冒号"),
            (#"{"a":1"#, 1, 7, "未闭合对象"),
            ("[1", 1, 3, "未闭合数组"),
            (#""abc"#, 1, 5, "未闭合字符串"),
            ("123 456", 1, 5, "多个顶层值"),
            (#"{"a":"x\q"}"#, 1, 9, "非法转义"),
            (#"{"a":"\u12"}"#, 1, 11, #"\u 之后不足 4 位"#),
            (#"{"a":+1}"#, 1, 6, "显式正号"),
            (#"{"a":.5}"#, 1, 6, "缺整数部分"),
            ("{\"a\":\"x\ny\"}", 1, 8, "字符串里未转义的真换行"),
        ]
        for item in cases {
            let error = catching { try JSONTool.reformat(item.text) } as? JSONTool.Failure
            #expect(error?.line == item.line, "\(item.label) 的行号")
            #expect(error?.column == item.column, "\(item.label) 的列号")
        }
    }

    @Test("错误信息把位置写在前面，用户可以直接照着定位")
    func errorDescriptionLeadsWithPosition() throws {
        let error = catching { try JSONTool.reformat(#"{"a": 01}"#) } as? JSONTool.Failure
        #expect(error?.localizedDescription.hasPrefix("第 1 行第 8 列：") == true)
    }
}

@Suite("工具箱：二维码")
struct QRCodeTests {
    @Test("按 UTF-8 编码，中文与 emoji 的字节数正确")
    func encodesAsUTF8() throws {
        // 传给 CoreImage 的必须是 UTF-8 字节而不是 String：
        // 实测「中」(3 字节) 与「?」(1 字节) 生成的矩阵不同，说明非 ASCII 没被替换成 ?。
        #expect(try QRCode.payload(text: "中").count == 3)
        #expect(try QRCode.payload(text: "🎉").count == 4)
        #expect(try QRCode.payload(text: "hi").count == 2)
    }

    @Test("空输入被拒绝")
    func rejectsEmptyInput() {
        let error = catching { try QRCode.payload(text: "") } as? QRCodeError
        #expect(error == .emptyInput)
    }

    @Test("容量随纠错级别变化，超限时给出人话")
    func enforcesCorrectionLevelCapacity() throws {
        // 2000 字节在 M（2331）装得下，在 Q（1663）装不下。
        let text = String(repeating: "a", count: 2000)
        #expect((try? QRCode.payload(text: text, options: QRCodeOptions(correctionLevel: .medium))) != nil)

        let error = catching {
            try QRCode.payload(text: text, options: QRCodeOptions(correctionLevel: .quartile))
        } as? QRCodeError
        #expect(error == .tooLong(limit: 1663, actual: 2000))
        #expect(error?.localizedDescription.contains("内容太长") == true)
    }

    @Test("各纠错级别的字节容量")
    func reportsCapacities() {
        #expect(QRCodeOptions.CorrectionLevel.low.byteCapacity == 2953)
        #expect(QRCodeOptions.CorrectionLevel.medium.byteCapacity == 2331)
        #expect(QRCodeOptions.CorrectionLevel.quartile.byteCapacity == 1663)
        #expect(QRCodeOptions.CorrectionLevel.high.byteCapacity == 1273)
    }

    @Test("参数被夹进合法范围")
    func normalizesOptions() {
        #expect(QRCodeOptions(scale: 0).normalized.scale == 1)
        #expect(QRCodeOptions(scale: 999).normalized.scale == 64)
        #expect(QRCodeOptions(quietZone: -5).normalized.quietZone == 0)
        #expect(QRCodeOptions(quietZone: 99).normalized.quietZone == 16)
    }

    @Test("占位渲染器明确失败，不假装成功")
    func placeholderRendererFailsLoudly() {
        #expect(UnavailableQRCodeRenderer().render(payload: Data("x".utf8), options: QRCodeOptions()) == nil)
    }
}

@Suite("工具箱：JSON 工作区状态")
struct JSONToolWorkspaceTests {
    @Test("空输入不报错——刚清空文本框就被红字骂一句是噪音")
    func staysQuietOnEmptyInput() {
        var subject = JSONToolWorkspace()
        subject.compute()
        #expect(subject.output == nil)
        #expect(subject.failure == nil)

        subject.input = "  \n\t "
        #expect(subject.isEmpty)
        subject.compute()
        #expect(subject.failure == nil)
    }

    @Test("改参数与输入后结果随之更新")
    func recomputesOnChange() {
        var subject = JSONToolWorkspace()
        subject.input = #"{"b":1,"a":2}"#
        subject.compute()
        #expect(subject.output == "{\n  \"b\": 1,\n  \"a\": 2\n}")

        subject.isCompact = true
        subject.compute()
        #expect(subject.output == #"{"b":1,"a":2}"#)
    }

    @Test("失败时清掉上一次的输出，不留旧结果骗人")
    func clearsStaleOutputOnFailure() {
        var subject = JSONToolWorkspace()
        subject.input = #"{"a":1}"#
        subject.compute()
        #expect(subject.output != nil)

        subject.input = "{bad}"
        subject.compute()
        #expect(subject.output == nil)
        #expect(subject.failure?.line == 1)
    }

    @Test("用结果替换输入；没有结果时不动输入")
    func adoptsOutputOnlyWhenAvailable() {
        var subject = JSONToolWorkspace()
        subject.input = #"{"x":[1,2]}"#
        subject.compute()
        let formatted = subject.output
        // 先把返回值取出来再断言：直接写 `#expect(subject.adoptOutput())` 会展开成
        // 对 `$0` 的调用，而宏展开后那个 `$0` 是不可变的，mutating 方法调不通。
        let adopted = subject.adoptOutput()
        #expect(adopted)
        #expect(subject.input == formatted)

        subject.input = "{oops}"
        subject.compute()
        let broken = subject.input
        let adoptedAgain = subject.adoptOutput()
        #expect(!adoptedAgain)
        #expect(subject.input == broken)
    }
}

@Suite("工具箱：二维码工作区状态")
struct QRCodeWorkspaceTests {
    /// 记录调用、可控返回的假渲染器。
    ///
    /// 这正是端口存在的意义：出图要用 CoreImage，但「容量校验先于渲染」
    /// 这类顺序约束不必真的画一张图才能验。
    private final class FakeRenderer: QRCodeRendering, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var lastOptions: QRCodeOptions?
        var returnsNil = false

        func render(payload: Data, options: QRCodeOptions) -> QRCodeBitmap? {
            callCount += 1
            lastOptions = options
            return returnsNil ? nil : QRCodeBitmap(pngData: Data("png".utf8), pixelWidth: 8, pixelHeight: 8)
        }
    }

    @Test("空输入不起渲染任务")
    func doesNotRenderEmptyInput() {
        let renderer = FakeRenderer()
        var subject = QRCodeWorkspace()
        subject.compute(renderer: renderer)
        #expect(renderer.callCount == 0)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage == nil)
    }

    @Test("容量校验先于渲染：超长输入不去调渲染器")
    func validatesBeforeRendering() {
        let renderer = FakeRenderer()
        var subject = QRCodeWorkspace()
        subject.input = String(repeating: "a", count: 3000)
        subject.options = QRCodeOptions(correctionLevel: .high)
        subject.compute(renderer: renderer)

        #expect(renderer.callCount == 0)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage?.contains("内容太长") == true)
    }

    @Test("渲染失败时给出说法，恢复后错误被清掉")
    func reportsRenderFailureAndRecovers() {
        let renderer = FakeRenderer()
        var subject = QRCodeWorkspace()
        subject.input = "ok"
        renderer.returnsNil = true
        subject.compute(renderer: renderer)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage != nil)

        renderer.returnsNil = false
        subject.compute(renderer: renderer)
        #expect(subject.bitmap != nil)
        #expect(subject.errorMessage == nil)
    }

    @Test("参数原样透传给渲染器")
    func passesOptionsThrough() {
        let renderer = FakeRenderer()
        var subject = QRCodeWorkspace()
        subject.input = "hi"
        subject.options = QRCodeOptions(correctionLevel: .high, scale: 3, quietZone: 1)
        subject.compute(renderer: renderer)
        #expect(renderer.lastOptions?.correctionLevel == .high)
        #expect(renderer.lastOptions?.scale == 3)
        #expect(renderer.lastOptions?.quietZone == 1)
    }

    @Test("美化样式随 options 透传给渲染器")
    func passesStyleThrough() {
        let renderer = FakeRenderer()
        var subject = QRCodeWorkspace()
        subject.input = "hi"
        subject.options = QRCodeOptions(style: QRCodeStyle(shape: .circle, logoData: Data("logo".utf8)))
        subject.compute(renderer: renderer)
        #expect(renderer.lastOptions?.style.shape == .circle)
        #expect(renderer.lastOptions?.style.logoData != nil)
    }
}

@Suite("工具箱：二维码美化样式")
struct QRCodeStyleTests {
    @Test("默认样式是纯标准态：黑白方块、无 Logo")
    func defaultIsPlain() {
        let style = QRCodeStyle.default
        #expect(style.isPlain)
        #expect(style.shape == .square)
        #expect(style.foreground == .black)
        #expect(style.background == .white)
        #expect(style.logoData == nil)
    }

    @Test("任一美化项偏离标准就不再是纯样式，渲染层要走慢路")
    func anyDeviationMakesItStyled() {
        #expect(!QRCodeStyle(shape: .rounded).isPlain)
        #expect(!QRCodeStyle(foreground: QRColor(rgb: 0xFF0000)).isPlain)
        #expect(!QRCodeStyle(background: QRColor(rgb: 0x00FF00)).isPlain)
        #expect(!QRCodeStyle(logoData: Data("x".utf8)).isPlain)
    }

    @Test("Logo 比例被夹进安全范围")
    func clampsLogoScale() {
        #expect(QRCodeStyle(logoScale: 0.01).normalized.logoScale == 0.05)
        #expect(QRCodeStyle(logoScale: 0.9).normalized.logoScale == 0.3)
        #expect(QRCodeStyle(logoScale: 0.2).normalized.logoScale == 0.2)
    }

    @Test("颜色分量被夹进 0...1，十六进制可往返")
    func normalizesColorComponents() {
        let clamped = QRColor(red: 2, green: -1, blue: 0.5)
        #expect(clamped.red == 1)
        #expect(clamped.green == 0)
        #expect(clamped.blue == 0.5)
        #expect(QRColor(rgb: 0x336699).rgbValue == 0x336699)
    }

    @Test("样式 token 随任一影响结果的参数变化；与标准态不同")
    func tokenChangesWithStyledParams() {
        let base = QRCodeStyle.default.fingerprintToken
        #expect(QRCodeStyle(shape: .circle).fingerprintToken != base)
        #expect(QRCodeStyle(foreground: QRColor(rgb: 0xFF0000)).fingerprintToken != base)
        #expect(QRCodeStyle(logoData: Data("a".utf8)).fingerprintToken != base)
        #expect(QRCodeStyle(logoScale: 0.25).fingerprintToken != base)
    }
}

@Suite("工具箱：WiFi 二维码载荷")
struct WiFiQRCodePayloadTests {
    @Test("WPA + 密码 + 隐藏：标准字段依次拼接，末尾双分号")
    func wpaFull() throws {
        let text = try WiFiQRCode.payload(ssid: "Cafe", password: "secret", encryption: .wpa, isHidden: true)
        #expect(text == "WIFI:T:WPA;S:Cafe;P:secret;H:true;;")
    }

    @Test("无密码：不写 P 字段，T 为 nopass")
    func openNetworkOmitsPassword() throws {
        let text = try WiFiQRCode.payload(ssid: "FreeWiFi", password: "", encryption: .none, isHidden: false)
        #expect(text == "WIFI:T:nopass;S:FreeWiFi;;")
    }

    @Test("WEP 保留密码字段")
    func wepKeepsPassword() throws {
        let text = try WiFiQRCode.payload(ssid: "old", password: "pw123", encryption: .wep, isHidden: false)
        #expect(text == "WIFI:T:WEP;S:old;P:pw123;;")
    }

    @Test("SSID 为空报错，不静默生成半截载荷")
    func emptySSIDThrows() {
        let error = catching {
            try WiFiQRCode.payload(ssid: "   ", password: "x", encryption: .wpa, isHidden: false)
        }
        #expect(error as? WiFiQRCode.Error == .emptySSID)
    }

    @Test("需要密码的加密方式为空密码报错")
    func emptyPasswordThrowsWhenRequired() {
        let error = catching {
            try WiFiQRCode.payload(ssid: "net", password: "", encryption: .wpa, isHidden: false)
        }
        #expect(error as? WiFiQRCode.Error == .emptyPassword)
    }

    @Test("SSID / 密码里的分隔符被反斜杠转义")
    func escapesSpecialCharacters() throws {
        let text = try WiFiQRCode.payload(ssid: "a;b", password: "p:w,q\"z\\", encryption: .wpa, isHidden: false)
        #expect(text == "WIFI:T:WPA;S:a\\;b;P:p\\:w\\,q\\\"z\\\\;;")
    }
}

@Suite("工具箱：WiFi 二维码工作区状态")
struct WiFiQRCodeWorkspaceTests {
    private final class FakeRenderer: QRCodeRendering, @unchecked Sendable {
        private(set) var callCount = 0
        private(set) var lastPayload: Data?
        var returnsNil = false

        func render(payload: Data, options: QRCodeOptions) -> QRCodeBitmap? {
            callCount += 1
            lastPayload = payload
            return returnsNil ? nil : QRCodeBitmap(pngData: Data("png".utf8), pixelWidth: 8, pixelHeight: 8)
        }
    }

    @Test("SSID 为空不起渲染任务")
    func doesNotRenderEmptySSID() {
        let renderer = FakeRenderer()
        var subject = WiFiQRCodeWorkspace()
        subject.password = "x"
        subject.compute(renderer: renderer)
        #expect(renderer.callCount == 0)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage == nil)
    }

    @Test("填齐后渲染，载荷是拼好的 WIFI 文本")
    func rendersWhenFilled() {
        let renderer = FakeRenderer()
        var subject = WiFiQRCodeWorkspace()
        subject.ssid = "Cafe"
        subject.password = "secret"
        subject.compute(renderer: renderer)
        #expect(renderer.callCount == 1)
        #expect(subject.bitmap != nil)
        #expect(subject.errorMessage == nil)
        #expect(String(data: renderer.lastPayload ?? Data(), encoding: .utf8) == "WIFI:T:WPA;S:Cafe;P:secret;;")
    }

    @Test("密码缺失时报错并清掉旧图")
    func reportsMissingPassword() {
        let renderer = FakeRenderer()
        var subject = WiFiQRCodeWorkspace()
        subject.ssid = "Cafe"
        subject.password = "secret"
        subject.compute(renderer: renderer)
        #expect(subject.bitmap != nil)

        subject.password = ""
        subject.compute(renderer: renderer)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage?.contains("密码") == true)
    }

    @Test("渲染器返回 nil 时给出说法")
    func reportsRenderFailure() {
        let renderer = FakeRenderer()
        renderer.returnsNil = true
        var subject = WiFiQRCodeWorkspace()
        subject.ssid = "net"
        subject.password = "pw"
        subject.compute(renderer: renderer)
        #expect(subject.bitmap == nil)
        #expect(subject.errorMessage != nil)
    }

    @Test("美化样式随 options 透传给渲染器")
    func passesStyleThrough() {
        let renderer = FakeRenderer()
        var subject = WiFiQRCodeWorkspace()
        subject.ssid = "net"
        subject.password = "pw"
        subject.options = QRCodeOptions(correctionLevel: .high, style: QRCodeStyle(foreground: QRColor(rgb: 0xFF0000)))
        subject.compute(renderer: renderer)
        #expect(renderer.lastPayload != nil)
    }
}

@Suite("工具箱：过期结果识别")
struct ToolboxFingerprintTests {
    private func json(_ input: String, indent: JSONTool.Indent = .spaces(2), compact: Bool = false) -> String {
        ToolboxFingerprint.make(.jsonFormatter, input: input, indent: indent, isCompact: compact, options: QRCodeOptions())
    }

    private func qr(_ input: String, options: QRCodeOptions = QRCodeOptions()) -> String {
        ToolboxFingerprint.make(.qrCode, input: input, indent: .spaces(2), isCompact: false, options: options)
    }

    private func wifi(_ fields: String, options: QRCodeOptions = QRCodeOptions()) -> String {
        ToolboxFingerprint.make(.wifiQRCode, input: fields, indent: .spaces(2), isCompact: false, options: options)
    }

    @Test("输入、缩进、压缩开关变了，指纹都跟着变")
    func changesWithJSONState() {
        // 用户连着敲字时会有多次计算在飞，先发起的慢计算可能后回来。
        // 少了这道判断，它会用旧输入的结果盖掉新结果。
        #expect(json("a") != json("b"))
        #expect(json("a", indent: .spaces(2)) != json("a", indent: .spaces(4)))
        #expect(json("a", indent: .spaces(4)) != json("a", indent: .tab))
        #expect(json("a", compact: false) != json("a", compact: true))
    }

    @Test("同样的输入与参数给出同样的指纹")
    func isStable() {
        #expect(json("a") == json("a"))
    }

    @Test("二维码的纠错级别与缩放影响指纹")
    func changesWithQRCodeOptions() {
        #expect(qr("a", options: QRCodeOptions(correctionLevel: .low))
                != qr("a", options: QRCodeOptions(correctionLevel: .high)))
        #expect(qr("a", options: QRCodeOptions(scale: 5)) != qr("a", options: QRCodeOptions(scale: 10)))
    }

    @Test("美化样式变了，二维码指纹也跟着变（否则换 Logo 不重算）")
    func changesWithQRCodeStyle() {
        #expect(qr("a", options: QRCodeOptions(style: .default))
                != qr("a", options: QRCodeOptions(style: QRCodeStyle(shape: .rounded))))
        #expect(qr("a", options: QRCodeOptions(style: QRCodeStyle(logoData: Data("x".utf8))))
                != qr("a", options: QRCodeOptions(style: .default)))
    }

    @Test("WiFi 任一字段或样式变化都翻转指纹")
    func changesWithWiFiFields() {
        #expect(wifi("net\u{1F}pw\u{1F}wpa\u{1F}false") != wifi("net2\u{1F}pw\u{1F}wpa\u{1F}false"))
        #expect(wifi("net\u{1F}pw\u{1F}wpa\u{1F}false") != wifi("net\u{1F}pw\u{1F}wep\u{1F}false"))
        #expect(wifi("net\u{1F}pw\u{1F}wpa\u{1F}false") != wifi("net\u{1F}pw\u{1F}wpa\u{1F}true"))
        #expect(wifi("net", options: QRCodeOptions(style: .default))
                != wifi("net", options: QRCodeOptions(style: QRCodeStyle(foreground: QRColor(rgb: 0xFF0000)))))
        // 与通用二维码不串味：同样的原始输入也不应撞上。
        #expect(wifi("a") != qr("a"))
    }

    @Test("工具之间不串味：改二维码参数不该让 JSON 重算")
    func isolatesTools() {
        #expect(json("a") != qr("a"))
        #expect(json("a") == ToolboxFingerprint.make(
            .jsonFormatter, input: "a", indent: .spaces(2), isCompact: false,
            options: QRCodeOptions(correctionLevel: .high)
        ))
    }
}

@Suite("工具箱：工具清单")
struct ToolIdentifierTests {
    @Test("共 13 个工具，id 互不重复")
    func exposesThirteenDistinctTools() {
        #expect(ToolIdentifier.allCases.count == 13)
        #expect(Set(ToolIdentifier.allCases.map(\.id)).count == 13)
    }

    @Test("已实现的工具与未实现的分得清")
    func marksImplementedTools() {
        // 侧栏据此把未实现的置灰。没实现的不该假装能用。
        #expect(ToolIdentifier.allCases.filter(\.isImplemented) == [.jsonFormatter, .qrCode, .wifiQRCode, .passwordGenerator])
    }
}

@Suite("工具箱：随机密码")
struct PasswordGeneratorTests {
    // MARK: - 字符池组装

    @Test("默认参数：长度 16，大小写与数字开、符号关")
    func defaultsAreSensible() {
        let options = PasswordOptions()
        #expect(options.length == 16)
        #expect(options.includesLowercase && options.includesUppercase && options.includesDigits)
        #expect(!options.includesSymbols)
        #expect(!options.excludesAmbiguous)
    }

    @Test("字符池只包含启用字符集的字")
    func poolContainsOnlyEnabledSets() {
        let onlyDigits = PasswordGenerator.pool(options: PasswordOptions(
            includesLowercase: false, includesUppercase: false, includesDigits: true, includesSymbols: false
        ))
        #expect(Set(onlyDigits) == Set("0123456789"))

        let lowerOnly = PasswordGenerator.pool(options: PasswordOptions(
            includesLowercase: true, includesUppercase: false, includesDigits: false, includesSymbols: false
        ))
        #expect(Set(lowerOnly) == Set("abcdefghijklmnopqrstuvwxyz"))
    }

    @Test("排除易混淆字符把 0 O 1 l I 从池中剔掉")
    func excludesAmbiguousCharacters() {
        let plain = PasswordGenerator.pool(options: PasswordOptions(excludesAmbiguous: false))
        let filtered = PasswordGenerator.pool(options: PasswordOptions(excludesAmbiguous: true))
        for ambiguous in PasswordGenerator.ambiguousCharacters {
            #expect(plain.contains(ambiguous), "不排除时池里有「\(ambiguous)」")
            #expect(!filtered.contains(ambiguous), "排除后池里不应有「\(ambiguous)」")
        }
    }

    @Test("所有字符集都关掉时池为空")
    func emptyWhenAllSetsOff() {
        let options = PasswordOptions(
            includesLowercase: false, includesUppercase: false, includesDigits: false, includesSymbols: false
        )
        #expect(PasswordGenerator.pool(options: options).isEmpty)
    }

    // MARK: - 生成

    @Test("生成长度被夹进合法范围")
    func clampsLength() throws {
        #expect(try PasswordGenerator.generate(options: PasswordOptions(length: 1)).count == PasswordGenerator.minimumLength)
        #expect(try PasswordGenerator.generate(options: PasswordOptions(length: 99_999)).count == PasswordGenerator.maximumLength)
        let fifteen = try PasswordGenerator.generate(options: PasswordOptions(length: 15))
        #expect(fifteen.count == 15)
    }

    @Test("产物只含启用字符集的字（多轮验证安全随机不越池）")
    func outputRespectsPool() throws {
        let options = PasswordOptions(includesSymbols: true)
        let pool = Set(PasswordGenerator.pool(options: options))
        for _ in 0..<50 {
            let password = try PasswordGenerator.generate(options: options)
            #expect(Set(password).isSubset(of: pool))
        }
    }

    @Test("排除易混淆时产物不含这些字符")
    func outputOmitsAmbiguous() throws {
        let options = PasswordOptions(excludesAmbiguous: true)
        for _ in 0..<200 {
            let password = try PasswordGenerator.generate(options: options)
            #expect(password.firstIndex(where: { PasswordGenerator.ambiguousCharacters.contains($0) }) == nil)
        }
    }

    @Test("字符集全空时拒绝，不生成空密码")
    func rejectsEmptyPool() {
        let options = PasswordOptions(
            includesLowercase: false, includesUppercase: false, includesDigits: false, includesSymbols: false
        )
        let error = catching { try PasswordGenerator.generate(options: options) } as? PasswordError
        #expect(error == .emptyCharacterSets)
    }

    @Test("多轮生成不总是同一个（安全随机而非固定值）")
    func isNotConstant() throws {
        var seen = Set<String>()
        for _ in 0..<10 {
            seen.insert(try PasswordGenerator.generate(options: PasswordOptions(length: 24)))
        }
        #expect(seen.count > 1)
    }
}

@Suite("工具箱：随机密码工作区状态")
struct PasswordGeneratorWorkspaceTests {
    @Test("参数改动不影响已生成密码")
    func paramChangeKeepsExistingPassword() {
        var subject = PasswordGeneratorWorkspace()
        subject.generate()
        let generated = subject.password
        #expect(!generated.isEmpty)

        subject.options.length = 24
        // 参数只改状态，不自动重生成。
        #expect(subject.password == generated)
    }

    @Test("字符集全空时生成失败：清掉旧密码并留下说法")
    func failureClearsPassword() {
        var subject = PasswordGeneratorWorkspace()
        subject.generate()
        #expect(!subject.password.isEmpty)

        subject.options.includesLowercase = false
        subject.options.includesUppercase = false
        subject.options.includesDigits = false
        #expect(!subject.canGenerate)

        subject.generate()
        #expect(subject.password.isEmpty)
        #expect(subject.errorMessage != nil)

        // 恢复字符集后重新生成，错误提示被清掉。
        subject.options.includesDigits = true
        #expect(subject.canGenerate)
        subject.generate()
        #expect(!subject.password.isEmpty)
        #expect(subject.errorMessage == nil)
    }
}

@Suite("工具箱：预算与超时")
struct ToolWorkTests {
    @Test("正常返回结果")
    func returnsResult() async throws {
        #expect(try await ToolWork.run(ToolBudget.standard, input: "abc") { 42 } == 42)
    }

    @Test("超过输入上限时拒绝，且不起任务")
    func rejectsOversizedInput() async {
        let error = await catchingAsync {
            try await ToolWork.run(ToolBudget(inputLimit: 3, timeout: 5), input: "abcd") { 1 }
        } as? ToolFailure
        #expect(error == .inputTooLong(limit: 3, actual: 4))
    }

    @Test("工具自身的错误原样传出，不被包成泛泛的话")
    func propagatesToolErrors() async {
        let error = await catchingAsync {
            try await ToolWork.run(ToolBudget.standard, input: "x") {
                throw JSONTool.Failure(line: 2, column: 3, message: "工具自己的错")
            }
        } as? JSONTool.Failure
        #expect(error?.line == 2)
        #expect(error?.column == 3)
    }

    @Test("超时真的兑现，不等那个卡住的任务")
    func timesOutWithoutWaitingForStuckWork() async {
        // 这条是 `ToolWork` 刻意避开 `withTaskGroup` 的理由：任务组在作用域退出时
        // 会等待所有子任务，而 `NSRegularExpression` 一旦进入指数级回溯就在 C 层
        // 阻塞、无法从外部打断——用任务组做超时等于把调用方一起挂住。
        let start = Date()
        let error = await catchingAsync {
            try await ToolWork.run(ToolBudget(inputLimit: 100, timeout: 0.3), input: "x") {
                Thread.sleep(forTimeInterval: 5)   // 模拟不可中断的计算
                return 1
            }
        } as? ToolFailure
        let elapsed = Date().timeIntervalSince(start)
        #expect(error == .timedOut(seconds: 0.3))
        #expect(elapsed < 2, "函数没有等待那个要跑 5 秒的任务（实际 \(elapsed) 秒）")
    }
}

@Suite("控制台：选中项的存续规则")
struct ConsoleSelectionValidityTests {
    private let groups: Set<String> = [Group.ungroupedID, "dev"]

    @Test("工具与磁盘无关，任何快照下都有效")
    func toolsAreAlwaysAvailable() {
        // 这条规则写错了很难发现：没有它，`LibrarySync` 推来一次快照就会把
        // 正在用工具的人踢回分组列表——工具好好的，用户的输入却没了。
        #expect(ConsoleSelectionValidity.isAvailable(.tool(.jsonFormatter), groupIDs: groups, hasMissing: false))
        #expect(ConsoleSelectionValidity.isAvailable(.tool(.qrCode), groupIDs: [], hasMissing: false))
        #expect(ConsoleSelectionValidity.isAvailable(.tool(.qrCode), groupIDs: [], hasMissing: true))
    }

    @Test("分组与失效栏按快照内容判定")
    func groupsAndMissingFollowSnapshot() {
        #expect(ConsoleSelectionValidity.isAvailable(.group("dev"), groupIDs: groups, hasMissing: false))
        #expect(!ConsoleSelectionValidity.isAvailable(.group("gone"), groupIDs: groups, hasMissing: false))
        #expect(ConsoleSelectionValidity.isAvailable(.missing, groupIDs: groups, hasMissing: true))
        #expect(!ConsoleSelectionValidity.isAvailable(.missing, groupIDs: groups, hasMissing: false))
        #expect(!ConsoleSelectionValidity.isAvailable(nil, groupIDs: groups, hasMissing: true))
    }

    @Test("工具栏下没有应用可见，详情面板该收起来")
    func toolsListNoApplications() {
        #expect(!ConsoleSelectionValidity.isListed(
            "com.example.a",
            selection: .tool(.jsonFormatter),
            missingIdentifiers: [],
            visibleIdentifiers: ["com.example.a"]
        ))
        #expect(ConsoleSelectionValidity.isListed(
            "com.example.a",
            selection: .group("dev"),
            missingIdentifiers: [],
            visibleIdentifiers: ["com.example.a"]
        ))
        #expect(ConsoleSelectionValidity.isListed(
            "com.gone.app",
            selection: .missing,
            missingIdentifiers: ["com.gone.app"],
            visibleIdentifiers: []
        ))
    }
}
