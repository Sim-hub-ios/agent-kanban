import AppKit
import SwiftUI
import AgentKanbanCore

/// Values come from the editable Figma color collection, with semantic dark variants.
enum KanbanTheme {
    static let ink = adaptive("1D283A", dark: "E4E9F2")
    static let muted = adaptive("607086", dark: "A9B7CA")
    static let background = adaptive("F5F6F8", dark: "171C24")
    static let panel = adaptive("FFFFFF", dark: "202731")
    static let sidebar = adaptive("E9EFFA", dark: "202938")
    static let line = adaptive("DCE1EA", dark: "364150")
    static let blue = adaptive("3264DB", dark: "88A9FF")
    static let blueSoft = adaptive("EDF2FE", dark: "253653")
    static let green = adaptive("1E765F", dark: "65CFAD")
    static let greenSoft = adaptive("EAF5F2", dark: "223E37")
    static let orange = adaptive("985F1C", dark: "EDB26A")
    static let orangeSoft = adaptive("FAF2E7", dark: "453629")
    static let purple = adaptive("805BB7", dark: "B99AE8")
    static let purpleSoft = adaptive("F3EFF9", dark: "352E45")
    static let hover = adaptive("F6F8FC", dark: "272F3C")
    static let danger = adaptive("BF4444", dark: "F18B8B")
    static let sidebarWidth: CGFloat = 232
    static let titlebarHeight: CGFloat = 48
    static let statusbarHeight: CGFloat = 28

    static func effort(_ value: String?) -> Color {
        let hex: String = switch value?.lowercased() {
        case "low": "317AA3"
        case "medium": "466BC5"
        case "high": "625ECC"
        case "xhigh": "7853CA"
        case "max": "8A48C7"
        case "ultra": "9A3DBF"
        default: "52758D"
        }
        return adaptive(hex, dark: hex, lightenDark: 0.28)
    }

    private static func adaptive(_ light: String, dark: String, lightenDark: CGFloat = 0) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = Int(isDark ? dark : light, radix: 16) ?? 0
            let blend = isDark ? lightenDark : 0
            func component(_ shift: Int) -> CGFloat { CGFloat((value >> shift) & 0xFF) / 255 * (1 - blend) + blend }
            return NSColor(srgbRed: component(16), green: component(8), blue: component(0), alpha: 1)
        })
    }
}

@MainActor
private enum DesignAssets {
    static var cache: [String: NSImage] = [:]
    static func image(_ name: String, brand: Bool = false) -> NSImage? {
        if let image = cache[name] { return image }
        let folder = brand ? "Resources" : "Resources/Figma"
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "pdf", subdirectory: folder),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct DesignIcon: View {
    let name: String
    var size: CGFloat = 18
    var color: Color = KanbanTheme.muted
    var body: some View {
        Group {
            if let asset = DesignAssets.image(name) {
                Image(nsImage: asset).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "questionmark.square").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size).foregroundStyle(color).accessibilityHidden(true)
    }
}

struct ExecutorIcon: View {
    let executor: ExecutorID
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let asset = DesignAssets.image(executor.rawValue, brand: true) {
                Image(nsImage: asset).resizable().renderingMode(.template).scaledToFit()
            } else {
                Text(executor.title.prefix(1)).font(.system(size: size, weight: .semibold))
            }
        }
        .frame(width: size, height: size).foregroundStyle(KanbanTheme.ink).accessibilityLabel(executor.title)
    }
}

struct StatusChip: View {
    let text: String
    var color: Color = KanbanTheme.muted
    var background: Color = KanbanTheme.sidebar
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            .foregroundStyle(color).padding(.horizontal, 6).frame(minHeight: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct PanelModifier: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content.background(KanbanTheme.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(KanbanTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 3, y: 2)
    }
}

/// The brand fill remains legible when the window loses key status; disabled actions still dim.
struct KanbanPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Color(red: 50 / 255, green: 100 / 255, blue: 219 / 255)
    var circle = false
    var minWidth: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = circle ? 36 : controlSize == .mini ? 24 : controlSize == .small ? 28 : 36
        configuration.label
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, circle ? 0 : 14)
            .frame(width: circle ? 36 : nil).frame(minWidth: minWidth, minHeight: height)
            .background(LinearGradient(colors: [tint.opacity(0.88), tint], startPoint: .top, endPoint: .bottom), in: Capsule())
            .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
            .shadow(color: tint.opacity(isEnabled ? 0.18 : 0), radius: 4.5, x: 0, y: 3)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    func contentPanel(radius: CGFloat = 14) -> some View { modifier(PanelModifier(radius: radius)) }
}

extension TaskPhase {
    var color: Color {
        switch self {
        case .backlog: KanbanTheme.muted
        case .discussion: KanbanTheme.purple
        case .development: KanbanTheme.blue
        case .acceptance: KanbanTheme.orange
        case .completed: KanbanTheme.green
        }
    }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .waitingApproval, .recoveryRequired: KanbanTheme.orange
        case .running, .starting, .queued, .cancelling: KanbanTheme.blue
        case .succeeded: KanbanTheme.green
        case .failed: KanbanTheme.danger
        case .cancelled: KanbanTheme.muted
        }
    }
}

func effortTitle(_ value: String?) -> String {
    switch value?.lowercased() {
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh": "超高"
    case "max": "最高"
    case "ultra": "Ultra"
    default: "默认"
    }
}

func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
