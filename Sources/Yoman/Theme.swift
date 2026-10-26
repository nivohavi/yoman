import AppKit
import SwiftUI

extension Color {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Google-Calendar-inspired palette that adapts to light and dark mode.
enum Theme {
    static let blue = Color.dynamic(rgb(0x1A73E8), rgb(0x8AB4F8))
    static let onBlue = Color.dynamic(.white, rgb(0x202124))
    static let bg = Color.dynamic(.white, rgb(0x1F1F1F))
    static let sidebar = Color.dynamic(rgb(0xF8FAFD), rgb(0x1B1B1B))
    static let card = Color.dynamic(.white, rgb(0x2D2E30))
    static let grid = Color.dynamic(rgb(0xDADCE0), rgb(0x3C4043))
    static let text = Color.dynamic(rgb(0x1F1F1F), rgb(0xE3E3E3))
    static let secondary = Color.dynamic(rgb(0x5F6368), rgb(0x9AA0A6))
    static let selected = Color.dynamic(rgb(0xD3E3FD), rgb(0x004A77))
    static let hover = Color.dynamic(rgb(0xF1F3F4), rgb(0x303134))
    static let pill = Color.dynamic(rgb(0xC2E7FF), rgb(0x004A77))
    /// Weekend column tint and label color.
    static let weekendBand = Color.dynamic(NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 0.07),
                                           NSColor(srgbRed: 0.54, green: 0.71, blue: 0.97, alpha: 0.10))
    static let weekendLabel = Color.dynamic(rgb(0x1967D2), rgb(0x8AB4F8))
    static let now = Color.dynamic(rgb(0xEA4335), rgb(0xF28B82))
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear))
            .overlay(Capsule().strokeBorder(Theme.grid))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onBlue)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(Theme.blue.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct CreateButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.leading, 14).padding(.trailing, 20).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(hovering ? Theme.pill : Theme.card))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.15), radius: hovering ? 4 : 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Colored check box used for calendar visibility.
struct ColorCheckbox: View {
    let color: Color
    let checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(checked ? color : .clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 2))
            .overlay {
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
    }
}

extension NSColor {
    /// Readable text color on top of this fill: dark on light colors (cyan, yellow…), white otherwise.
    var contrastingText: Color {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.62 ? Color(white: 0.12) : .white
    }
}

/// Small colored circle as an NSImage, for use inside menus (where SwiftUI shapes are dropped).
func colorDot(_ color: NSColor, size: CGFloat = 10) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        return true
    }
    return img
}

/// A dimmed backdrop + centred card, used for the event detail and editor dialogs.
struct ModalCard<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            content
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
                .padding(14)
        }
        .transition(.opacity)
    }
}
