import SwiftUI

/// Rotary control for one 0...100 parameter, the one control macOS has no stock version of.
/// Drag up or right to raise it, down or left to lower it. With keyboard focus the arrow
/// keys step by 1, and VoiceOver sees it as an adjustable value.
///
/// It follows the pointer directly with no animation: a control that is dragged
/// constantly should never lag behind the hand.
struct Knob: View {
    let label: String
    let value: Int
    var range: ClosedRange<Int> = 0...100
    let display: String
    var enabled = true
    /// Double-click action: put the value back to where it was saved.
    var onReset: (() -> Void)?
    let onChange: (Int) -> Void

    // Declared without the @State attribute: on this SDK it is a compiler macro whose plugin
    // ships only with full Xcode, and this project builds with the Command Line Tools alone.
    private var dragOriginStorage = State<Int?>(initialValue: nil)
    private var dragOrigin: Int? {
        get { dragOriginStorage.wrappedValue }
        nonmutating set { dragOriginStorage.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    init(label: String, value: Int, range: ClosedRange<Int> = 0...100, display: String, enabled: Bool = true,
         onReset: (() -> Void)? = nil, onChange: @escaping (Int) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.display = display
        self.enabled = enabled
        self.onReset = onReset
        self.onChange = onChange
    }

    private var fraction: Double {
        let span = Double(range.upperBound - range.lowerBound)
        return span > 0 ? Double(min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
    }

    private func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // 270 degree track, open at the bottom
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: max(0.0001, 0.75 * fraction))
                    .stroke(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.6)),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Cap: raised with two soft shadows rather than an outline
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .background(Circle().fill(.background))
                    .shadow(color: .black.opacity(0.16), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                    .padding(9)
                Capsule()
                    .fill(Color.primary.opacity(enabled ? 0.85 : 0.4))
                    .frame(width: 2.5, height: 9)
                    .offset(y: -14)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: 60, height: 60)
            .overlay {
                if focused {
                    Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 3).padding(-5)
                }
            }
            .contentShape(Circle())
            .onTapGesture(count: 2) { onReset?() }
            .help("Double-click to return to the saved value")
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragOrigin == nil { dragOrigin = value; focused = true }
                        let delta = Int(((g.translation.width - g.translation.height) / 1.6).rounded())
                        onChange(clamp((dragOrigin ?? value) + delta))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )

            VStack(spacing: 1) {
                Text(display)
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(minWidth: 92)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up, .right: onChange(clamp(value + 1))
            case .down, .left: onChange(clamp(value - 1))
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(clamp(value + 5))
            case .decrement: onChange(clamp(value - 5))
            default: break
            }
        }
    }
}
