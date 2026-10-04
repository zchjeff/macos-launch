import SwiftUI

// MARK: - Liquid Glass 接入层
//
// 视图层只回答一个问题：「这块东西是不是浮在内容之上」。至于浮起来之后长什么样，
// 由这一层决定：
//
// - macOS 26+：原生 Liquid Glass（`.glassEffect`）。交互元素带 `.interactive()`，
//   相邻玻璃用 `GlassEffectContainer` 组织，需要形变的挂 `glassEffectID`。
// - macOS 14/15：材质回退（`.ultraThinMaterial` / 给定材质）+ 旧样式的细描边。
// - 打开「降低透明度」时：两边都退回不透明底色。玻璃的前提是背后有内容，
//   而按了「降低透明度」的用户要的恰恰是「别透」——这时可读性优先于层次。
//
// 全部 `#available` 分支收在这一个文件里，有两个好处：视图代码保持干净；
// 也不会有人为了「看着像玻璃」去手写模糊和渐变——那种仿制在系统换皮时必然走样。

/// 这块玻璃是干什么用的。
enum GlassKind {
    /// 浮层、控制条、卡片。静静地浮着，不抢指针事件。
    case floating
    /// 可悬停、可按压的元素。指针靠近时有高光与形变响应。
    case interactive
}

/// 系统风格的动效刻度。
///
/// 覆盖层是「喊出来就用」的界面，动效要快；控制台是从容操作的地方，可以稍缓。
enum GlassMotion {
    /// 标准弹簧：快、不过冲。
    static let standard = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// 交互反馈：更短，手指还没抬起来就已经到位了。
    static let quick = Animation.spring(response: 0.28, dampingFraction: 0.72)
}

extension View {
    /// 给浮在内容之上的元素铺一层玻璃。
    ///
    /// - Parameters:
    ///   - kind: 静态浮层还是可交互元素。
    ///   - shape: 玻璃的形状，同时决定圆角。小控件 8–12、卡片/面板 16–20、按钮用 `.capsule`。
    ///   - tint: 轻微着色，用来表达状态（例如搜索框聚焦）。别用来当背景色。
    ///   - fallback: 旧系统（macOS 14/15）用的材质。
    @ViewBuilder
    func glassSurface<S: InsettableShape>(
        _ kind: GlassKind = .floating,
        in shape: S,
        tint: Color? = nil,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        modifier(GlassSurface(kind: kind, shape: shape, tint: tint, fallback: fallback))
    }

    /// 给玻璃元素挂身份。位置或尺寸变化时，玻璃会形变过去而不是跳过去（macOS 26+）。
    @ViewBuilder
    func glassIdentity(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// 同上，身份是可选的。格子在静止时根本不铺玻璃，也就没有身份——
    /// 悬停时玻璃浮起来，这时身份才存在。
    @ViewBuilder
    func glassIdentityIfPresent(_ id: String?, in namespace: Namespace.ID?) -> some View {
        if #available(macOS 26.0, *), let id, let namespace {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// 滚动边缘：内容滚到玻璃条底下时，边缘柔化而不是硬切（macOS 26+）。
    @ViewBuilder
    func glassScrollEdge(_ edges: Edge.Set = .top) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// 玻璃按钮：macOS 26 用系统 `.glass` / `.glassProminent`，旧系统回退到 bordered。
    ///
    /// 原来的按钮是 `.borderless`（例如检查器里的「设置…」）时，回退必须留在
    /// `.borderless`：换成 bordered 会让按钮变宽变高，整块面板的排版都跟着挪。
    @ViewBuilder
    func glassActionButton(prominent: Bool = false, borderlessFallback: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if borderlessFallback {
            buttonStyle(.borderless)
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `glassSurface` 的实现。所有版本分支都在这儿。
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let kind: GlassKind
    let shape: S
    let tint: Color?
    let fallback: Material

    /// 「降低透明度」：玻璃换不透明底色。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 「提高对比度」：描边加重一档，同时把玻璃垫实一点，文字不靠模糊也读得清。
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background { shape.fill(.background) }
                .overlay { shape.strokeBorder(.separator, lineWidth: borderWidth) }
        } else if #available(macOS 26.0, *) {
            content
                // 提高对比度时在玻璃背后垫一层半透明底色：玻璃是透的，
                // 背后实一点，压在上面的文字就多一分确定。玻璃仍然是玻璃。
                .background {
                    if contrast == .increased {
                        shape.fill(.background.opacity(0.55))
                    }
                }
                .glassEffect(glass, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(.separator, lineWidth: borderWidth)
                    }
                }
        } else {
            content
                .background(fallback, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: borderWidth) }
        }
    }

    /// 提高对比度时描边加重一倍，玻璃与内容的分界不靠模糊也能看出来。
    private var borderWidth: CGFloat {
        contrast == .increased ? 1 : 0.5
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var value: Glass = .regular
        if kind == .interactive { value = value.interactive() }
        if let tint { value = value.tint(tint) }
        return value
    }
}

/// 一组相关玻璃元素的容器：统一间距，让相邻的玻璃能互相融合、各自形变。
///
/// macOS 26 以下没有这个概念，直接透传内容——布局完全一致，回退不掉链子。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 20
    var content: Content

    init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 格子的按压反馈：轻轻缩一下再弹回来。只改视觉，不动命中区域与点击语义。
///
/// 用自定义 `ButtonStyle` 而不是系统玻璃按钮：格子是一个 96×96 的图标容器，
/// 玻璃已经铺在容器上了，系统按钮再套一层玻璃就是两层玻璃叠着——那正是要避免的浑浊。
struct GlassPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration, scale: scale)
    }

    private struct PressFeedback: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? scale : 1)
                .animation(
                    reduceMotion ? nil : GlassMotion.quick,
                    value: configuration.isPressed
                )
        }
    }
}
