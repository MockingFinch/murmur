import AppKit
import SwiftUI

// MARK: - Palette

extension Color {
    /// A color that follows the appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static let cardFill = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.055))
    static let cardStroke = adaptive(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.085))
    static let well = adaptive(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05))
    static let hairline = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
}

/// Murmur's colors: warm for the voice, cool for the model.
enum Brand {
    static let coral = Color(hex: 0xFF5A5F)
    static let rose = Color(hex: 0xFF3B7A)
    static let violet = Color(hex: 0x8B6CFF)
    static let azure = Color(hex: 0x4D8DFF)
    static let mint = Color(hex: 0x30C48D)
    static let amber = Color(hex: 0xFFB020)

    static let voice = LinearGradient(colors: [Color(hex: 0xFF7A59), Color(hex: 0xFF3B7A)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let polish = LinearGradient(colors: [Color(hex: 0x9C7BFF), Color(hex: 0x4D8DFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let overview = LinearGradient(colors: [Color(hex: 0x5AC8FA), Color(hex: 0x4D6BFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let translate = LinearGradient(colors: [Color(hex: 0x3DD6C0), Color(hex: 0x2F7BF5)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let graphite = LinearGradient(colors: [Color(hex: 0x8E8E93), Color(hex: 0x48484A)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ink = LinearGradient(colors: [Color(hex: 0x2A2D4A), Color(hex: 0x14152A)], startPoint: .top, endPoint: .bottom)
}

enum Motion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let smooth = Animation.spring(response: 0.48, dampingFraction: 0.86)
    static let gentle = Animation.easeInOut(duration: 0.25)
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardFill)
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardStroke, lineWidth: 0.5))
    }
}

/// A titled group of cards.
struct PageSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

/// A row in a card: a label (and a line of help) and a control.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 4)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.vertical, 10)
    }
}

// MARK: - Headers

struct GlyphTile: View {
    let symbol: String
    let gradient: LinearGradient
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(gradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

struct PageHeader: View {
    let symbol: String
    let gradient: LinearGradient
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GlyphTile(symbol: symbol, gradient: gradient, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .bold)).tracking(-0.3)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Key caps

struct KeyCap: View {
    let label: String
    var size: CGFloat = 26
    var dimmed = false

    var body: some View {
        Text(label)
            .font(.system(size: size * (label.count > 2 ? 0.42 : 0.52), weight: .semibold, design: .rounded))
            .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .padding(.horizontal, size * 0.28)
            .frame(minWidth: size, minHeight: size)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(Color.adaptive(light: NSColor(white: 0.80, alpha: 1), dark: NSColor(white: 0.08, alpha: 1)))
                        .offset(y: size * 0.06)
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(LinearGradient(colors: [Color.adaptive(light: .white, dark: NSColor(white: 0.30, alpha: 1)),
                                                      Color.adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.22, alpha: 1))],
                                             startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.adaptive(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.10)), lineWidth: 0.5)
                }
            )
            .padding(.bottom, size * 0.06)
    }
}

struct KeyCaps: View {
    let caps: [String]
    var size: CGFloat = 26
    var dimmed = false

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                KeyCap(label: cap, size: size, dimmed: dimmed)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Status

enum Health: Equatable {
    case ok, attention, problem, idle

    var color: Color {
        switch self {
        case .ok: return Brand.mint
        case .attention: return Brand.amber
        case .problem: return Brand.coral
        case .idle: return .secondary
        }
    }
}

struct StatusDot: View {
    let health: Health
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(health.color)
            .frame(width: size, height: size)
            .background(Circle().fill(health.color.opacity(0.25)).frame(width: size * 2, height: size * 2))
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

// MARK: - Fields

/// A key field: hidden by default, with an eye to reveal it.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .focused($focused)

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide" : "Show")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.well))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.hairline, lineWidth: focused ? 1.5 : 0.5)
        )
        .animation(Motion.gentle, value: focused)
    }
}

struct PlainField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.well))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.hairline, lineWidth: focused ? 1.5 : 0.5)
            )
            .animation(Motion.gentle, value: focused)
    }
}

// MARK: - Connection checks

enum CheckState: Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)
}

/// "Test" with its outcome next to it.
struct CheckButton: View {
    let title: String
    let state: CheckState
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if state == .running {
                        ProgressView().controlSize(.mini)
                    }
                    Text(state == .running ? "Testing…" : title)
                }
                .frame(minWidth: 96)
            }
            .buttonStyle(.glass)
            .disabled(disabled || state == .running)

            Group {
                switch state {
                case .passed(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.mint)
                case .failed(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.coral)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 0)
        }
        .animation(Motion.snappy, value: state)
    }
}

/// An external link, with its arrow.
struct LinkLabel: View {
    let title: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}

// MARK: - Shadows

/// A soft drop shadow under a rounded rectangle. When `prerendered` is on
/// (recording the README's demos), it is drawn from an image rendered once
/// and stretched: the same look, at a fraction of the cost offscreen.
struct SoftShadow: ViewModifier {
    nonisolated(unsafe) static var prerendered = false
    @MainActor private static var plates: [String: NSImage] = [:]

    let cornerRadius: CGFloat
    let opacity: Double
    let radius: CGFloat
    var y: CGFloat = 0

    func body(content: Content) -> some View {
        if Self.prerendered {
            let margin = (radius * 2).rounded(.up)
            let cap = margin + cornerRadius
            content.background {
                Image(nsImage: Self.plate(cornerRadius, opacity, radius))
                    .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap))
                    .padding(-margin)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        } else {
            content.shadow(color: .black.opacity(opacity), radius: radius, y: y)
        }
    }

    @MainActor private static func plate(_ corner: CGFloat, _ opacity: Double, _ radius: CGFloat) -> NSImage {
        let key = "\(corner)-\(opacity)-\(radius)"
        if let cached = plates[key] { return cached }
        let margin = (radius * 2).rounded(.up)
        let side = 2 * (margin + corner) + 2
        let scale: CGFloat = 2
        let px = Int(side * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        ctx.scaleBy(x: scale, y: scale)
        // Only the shadow: the shape is drawn far away, its shadow cast back here.
        let away: CGFloat = 10_000
        let rect = CGRect(x: margin + away, y: margin, width: side - 2 * margin, height: side - 2 * margin)
        ctx.setShadow(offset: CGSize(width: -away * scale, height: 0), blur: radius * scale,
                      color: NSColor.black.withAlphaComponent(opacity).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return NSImage() }
        let image = NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        plates[key] = image
        return image
    }
}
