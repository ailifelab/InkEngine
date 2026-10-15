import SwiftUI

enum ReadingTheme: String, CaseIterable, Identifiable {
    case white, warm, green, dark
    var id: String { rawValue }
    var label: String { switch self { case .white: return "白色"; case .warm: return "暖黄"; case .green: return "柔绿"; case .dark: return "黑色" } }
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
    var keycapSide: Color {
        switch self {
        case .white: return Color(white: 0.81)
        case .warm: return Color(red: 0.75, green: 0.65, blue: 0.44)
        case .green: return Color(red: 0.57, green: 0.69, blue: 0.53)
        case .dark: return Color(white: 0.025)
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
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        GlassEffectContainer(spacing: 4) { content }
    }
}

private struct InkGlassSurface: ViewModifier {
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

/// 不透明的塑料键帽位于更大的透明外壳内，文字和键帽一起被包覆。
struct KeycapButtonStyle: ButtonStyle {
    var selected = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        InkControl(configuration: configuration, selected: selected, compact: compact)
    }
}

private struct InkControl: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.paperTheme) private var paperTheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var height: CGFloat {
        #if os(macOS)
        compact ? 34 : 38
        #else
        44
        #endif
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
    private var core: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }
    private var theme: ReadingTheme { scheme == .dark ? .dark : paperTheme }
    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .medium))
            .foregroundStyle(scheme == .dark ? Color(white: 0.93) : Color(red: 0.14, green: 0.15, blue: 0.16))
            // 字印的微弱浮雕位于键帽表面，外壳反光覆盖在文字上方。
            .shadow(color: .white.opacity(scheme == .dark ? 0.10 : 0.80), radius: 0.2, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.14), radius: 0.25, x: 0, y: -0.3)
            .padding(.horizontal, compact ? 10 : 18).padding(.vertical, 9)
            .frame(minWidth: height, minHeight: height)
            .background {
                // 外壳比键帽更宽、更深；侧壁和顶面的柔和反光共同形成包覆感。
                shape.fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.12 : 0.38), .white.opacity(0.025), .black.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing))
                core.fill(theme.keycapSide)
                    .padding(.horizontal, 6).padding(.vertical, 6).offset(y: 2)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.15), radius: 2.2, y: 2)
                core.fill(LinearGradient(colors: theme.keycapColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(.horizontal, 7).padding(.vertical, 8).offset(y: -2)
            }
            .overlay {
                GeometryReader { geometry in
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.13 : 0.32), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: geometry.size.width * 1.1, height: geometry.size.height * 0.6)
                        .rotationEffect(.degrees(-10)).offset(x: -5, y: -5).blur(radius: 2)
                    Capsule().fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.45 : 0.8), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: geometry.size.height * 0.62)
                        .offset(x: 2, y: 6).blur(radius: 1.2)
                    Capsule().fill(.white.opacity(scheme == .dark ? 0.13 : 0.45))
                        .frame(width: max(0, geometry.size.width - 12), height: 3)
                        .offset(x: 6, y: geometry.size.height - 5).blur(radius: 1.2)
                    Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(scheme == .dark ? 0.16 : 0.40)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: geometry.size.height * 0.65)
                        .offset(x: geometry.size.width - 6, y: 7).blur(radius: 1.4)
                }.clipShape(shape).allowsHitTesting(false)
            }
            .contentShape(shape)
            .inkGlass(radius: 12, interactive: true, selected: selected, clear: true)
            .shadow(color: .black.opacity(scheme == .dark ? 0.20 : 0.08), radius: configuration.isPressed ? 0.8 : 3.5, y: configuration.isPressed ? 0.5 : 3)
            .opacity(enabled ? 1 : 0.45)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ModeTabs: View {
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
                    Text(value ? "编辑" : "阅读")
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
                    .accessibilityLabel(value ? "编辑" : "阅读")
                    .accessibilityValue(value == editing ? "已选择" : "")
            }
        }.padding(4)
            .inkGlass(radius: 24)
            .disabled(busy)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: editing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("文稿模式")
    }
}

private struct PaperThemeKey: EnvironmentKey { static let defaultValue = ReadingTheme.white }
extension EnvironmentValues {
    var paperTheme: ReadingTheme { get { self[PaperThemeKey.self] } set { self[PaperThemeKey.self] = newValue } }
}
