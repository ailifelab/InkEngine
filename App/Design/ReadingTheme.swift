import SwiftUI
import InkCore

enum ReadingTheme: String, CaseIterable, Identifiable {
    case white, warm, green, dark
    var id: String { rawValue }
    var label: String { switch self { case .white: return L10n.tr("白色"); case .warm: return L10n.tr("暖黄"); case .green: return L10n.tr("柔绿"); case .dark: return L10n.tr("黑色") } }
    var background: Color {
        switch self {
        case .white: return Color(red: 0.99, green: 0.987, blue: 0.975)
        case .warm: return Color(red: 0.95, green: 0.90, blue: 0.78)
        case .green: return Color(red: 0.85, green: 0.91, blue: 0.84)
        case .dark: return Color(red: 0.055, green: 0.075, blue: 0.095)
        }
    }
    var foreground: Color { self == .dark ? .white : Color(red: 0.10, green: 0.13, blue: 0.16) }
    var highlight: Color { self == .dark ? Color(red: 0.50, green: 0.78, blue: 1) : Color(red: 0.06, green: 0.26, blue: 0.47) }
    var keycapColors: [Color] {
        switch self {
        case .white: return [.white, Color(white: 0.985), Color(white: 0.945)]
        case .warm: return [Color(red: 1, green: 0.95, blue: 0.82), Color(red: 0.98, green: 0.91, blue: 0.72), Color(red: 0.91, green: 0.82, blue: 0.61)]
        case .green: return [Color(red: 0.92, green: 0.97, blue: 0.90), Color(red: 0.85, green: 0.93, blue: 0.82), Color(red: 0.75, green: 0.85, blue: 0.72)]
        case .dark: return [Color(white: 0.16), Color(white: 0.10), Color(white: 0.065)]
        }
    }
    var sidebar: Color {
        switch self {
        case .white: return Color(red: 0.966, green: 0.961, blue: 0.948)
        case .warm: return Color(red: 0.926, green: 0.873, blue: 0.751)
        case .green: return Color(red: 0.826, green: 0.884, blue: 0.814)
        case .dark: return Color(red: 0.045, green: 0.062, blue: 0.079)
        }
    }
}

/// 导航使用透明外壳，正文始终铺在不透明的主题纸面上。
enum InkChrome {
    static let accent = Color(red: 0.18, green: 0.42, blue: 0.68)
}

/// 相邻原生玻璃控件共用采样容器，避免各自折射造成视觉断裂。
struct InkGlassContainer<Content: View>: View {
    @Environment(\.locale) private var appLocale
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        GlassEffectContainer(spacing: 4) { content }
    }
}

private struct InkGlassSurface: ViewModifier {
    @Environment(\.locale) private var appLocale
    var radius: CGFloat
    var interactive = false
    var selected = false
    var clear = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.paperTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background {
                    shape.fill(theme.sidebar)
                        .overlay { if selected { shape.fill(InkChrome.accent.opacity(0.18)) } }
                }
            } else {
                // 折射、边缘反光和按压由系统玻璃提供；降低透明度时使用主题实体底色。
                content.glassEffect((clear ? Glass.clear : Glass.regular).tint(selected ? InkChrome.accent.opacity(0.18) : nil).interactive(interactive), in: shape)
            }
        }
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(scheme == .dark ? Color.white : Color.black, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func inkGlass(radius: CGFloat = 22, interactive: Bool = false, selected: Bool = false, clear: Bool = false) -> some View {
        modifier(InkGlassSurface(radius: radius, interactive: interactive, selected: selected, clear: clear))
    }
}

/// 使用一层系统玻璃替代旧键帽的多层渐变与阴影。
/// 只修饰标签，不嵌套新 Button，保持 Menu 原生动作与完整触控区域。
struct KeycapButtonStyle: ButtonStyle {
    var selected = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    private var height: CGFloat {
        #if os(macOS)
        compact ? 34 : 38
        #else
        44
        #endif
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 18)
            .frame(minWidth: height, minHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .inkGlass(radius: 12, interactive: true, selected: selected)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// 文稿工具栏的紧凑标签样式；Menu 与 Button 共用一致的点击范围。
/// 移动端至少 44 点，不能改成嵌套 Button 的样式，否则菜单动作与无障碍区域会失配。
struct WorkspaceControlStyle: ButtonStyle {
    @Environment(\.paperTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 7)
            #if os(macOS)
            .frame(minWidth: 30, minHeight: 30)
            #else
            .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(theme.highlight.opacity(configuration.isPressed ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// 面板完成操作：iOS 27 固定在尾部，26 及 macOS 使用系统确认项，窄窗口仍可访问。
struct InkPanelDoneToolbar: ToolbarContent {
    var identifier = "panelDone"
    let action: () -> Void
    var body: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27, *) {
            ToolbarItem(placement: .topBarPinnedTrailing) { done }
        } else {
            ToolbarItem(placement: .confirmationAction) { done }
        }
        #else
        ToolbarItem(placement: .confirmationAction) { done }
        #endif
    }
    private var done: some View {
        Button(L10n.tr("完成"), action: action)
            .buttonStyle(.automatic).accessibilityIdentifier(identifier)
    }
}

struct ModeTabs: View {
    @Environment(\.locale) private var appLocale
    let editing: Bool
    let busy: Bool
    let switchMode: () -> Void
    @Namespace private var selection
    @Environment(\.colorScheme) private var scheme
    @Environment(\.paperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tabHeight: CGFloat {
        #if os(macOS)
        32
        #else
        36
        #endif
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach([true, false], id: \.self) { value in
                Button { if value != editing { switchMode() } } label: {
                    Text(value ? L10n.tr("编辑") : L10n.tr("阅读"))
                        .font(.system(size: 13, weight: value == editing ? .semibold : .regular))
                        .foregroundStyle(scheme == .dark ? Color.white : Color.primary)
                        .frame(width: 53, height: tabHeight)
                        .contentShape(Capsule())
                        .background {
                            if value == editing {
                                Capsule().fill(scheme == .dark ? ReadingTheme.dark.keycapColors[1] : theme.keycapColors[0])
                                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "mode", in: selection)
                            }
                        }
                }.buttonStyle(.plain)
                    .accessibilityIdentifier(value == editing ? "selectedMode" : "modeToggle")
                    .accessibilityLabel(value ? L10n.tr("编辑") : L10n.tr("阅读"))
                    .accessibilityValue(value == editing ? L10n.tr("已选择") : "")
            }
        }.padding(4)
            .inkGlass(radius: 24)
            .disabled(busy)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: editing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("文稿模式"))
    }
}

private struct PaperThemeKey: EnvironmentKey { static let defaultValue = ReadingTheme.white }
extension EnvironmentValues {
    var paperTheme: ReadingTheme { get { self[PaperThemeKey.self] } set { self[PaperThemeKey.self] = newValue } }
}
