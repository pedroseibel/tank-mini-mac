import SwiftUI
import TankMiniCore

// The app uses system colours, materials, text styles and controls throughout, so it follows
// the Mac's light / dark appearance and accent colour. The only custom colour is each
// module's identity badge, which always means "this module" and nothing else.

extension Module {
    var color: Color {
        switch self {
        case .fx: return .orange
        case .amp: return .red
        case .mod: return .purple
        case .delay: return .blue
        case .reverb: return .teal
        case .cab: return .brown
        }
    }

    var symbol: String {
        switch self {
        case .fx: return "bolt.fill"
        case .amp: return "dial.medium.fill"
        case .mod: return "waveform"
        case .delay: return "repeat"
        case .reverb: return "dot.radiowaves.left.and.right"
        case .cab: return "hifispeaker.fill"
        }
    }
}

/// Coloured rounded-square glyph, in the style of System Settings' sidebar icons.
struct ModuleBadge: View {
    let module: Module
    var size: CGFloat = 24
    var active = true

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(active ? AnyShapeStyle(module.color.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: module.symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .animation(.easeOut(duration: 0.15), value: active)
            .accessibilityHidden(true)
    }
}

enum Metrics {
    /// Fill used for grouped surfaces: a touch darker than the window in light mode,
    /// a touch lighter in dark mode, like a system group box.
    static let groupFill = Color.primary.opacity(0.045)
    static let hairline = Color.primary.opacity(0.08)
    static let tileRadius: CGFloat = 10
}

/// No-bounce spring for layout changes; nothing moves when Reduce Motion is on.
struct MotionAware<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: value)
    }
}

extension View {
    func layoutSpring<V: Equatable>(value: V) -> some View { modifier(MotionAware(value: value)) }
}
