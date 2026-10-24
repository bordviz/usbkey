import SwiftUI

// Shared palette and controls for the management window and the menu-bar panel.
enum Brand {
    static let red = Color(red: 166 / 255, green: 7 / 255, blue: 7 / 255)
    static let canvas = Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255)
    static let sidebar = Color(red: 21 / 255, green: 22 / 255, blue: 26 / 255)
    static let surface = Color(red: 28 / 255, green: 29 / 255, blue: 34 / 255)
    static let raised = Color(red: 36 / 255, green: 37 / 255, blue: 43 / 255)
    static let ink = Color(red: 244 / 255, green: 243 / 255, blue: 240 / 255)
    static let muted = Color(red: 155 / 255, green: 156 / 255, blue: 165 / 255)
    static let line = Color.white.opacity(0.075)
}
struct ActionStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 11)
            .foregroundStyle(kind == .danger ? Color(red: 1, green: 0.5, blue: 0.48) : Brand.ink)
            .background(background.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(kind == .primary ? Color.white.opacity(0.09) : Brand.line))
            .opacity(enabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
    private var background: Color {
        switch kind { case .primary: return Brand.red; case .secondary: return Brand.raised; case .quiet: return .white.opacity(0.025); case .danger: return .red.opacity(0.08) }
    }
}
struct Surface<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Brand.line))
    }
}
struct ConnectionBadge: View {
    let connected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Color(red: 0.43, green: 0.83, blue: 0.64) : Brand.muted).frame(width: 6, height: 6)
            Text(connected ? "Подключён" : "Не подключён").font(.system(size: 11, weight: .medium))
        }.foregroundStyle(Brand.muted).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.035), in: Capsule())
    }
}
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).padding(13).background(Brand.canvas, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Brand.line)).foregroundStyle(Brand.ink)
    }
}
