import SwiftUI
import TankMiniCore

/// The tuner sheet. It draws the steadied reading from `PedalStore.tunerDisplay`
/// (see `TunerFilter`), never the pedal's raw stream.
struct TunerView: View {
    @EnvironmentObject var store: PedalStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let display = store.tunerDisplay
        let hasNote = display.note != nil
        let inTune = display.inTune
        let position = min(max(display.cents / 50, -1), 1) // -1 = 50 cents flat, +1 = 50 cents sharp

        VStack(spacing: 18) {
            VStack(spacing: 0) {
                Text(verbatim: display.noteName ?? "–")
                    .font(.system(size: 88, weight: .semibold, design: .rounded))
                    .foregroundStyle(inTune ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    .frame(height: 96)
                    .accessibilityLabel(Text(verbatim: display.noteName.map { String(localized: "Note \($0)") } ?? String(localized: "No note")))
                // Fixed-width digits so the number does not shift as it changes.
                Text(verbatim: hasNote ? centsText(display.cents) : " ")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(!hasNote)
            }

            VStack(spacing: 8) {
                // Deviation meter: centre is in tune, left is flat, right is sharp.
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack {
                        Capsule().fill(Color.primary.opacity(0.10)).frame(height: 4)
                        // In-tune window: 3 cents either side of centre.
                        Capsule().fill(Color.green.opacity(0.35)).frame(width: max(10, w * 0.06), height: 4)
                        ForEach([-1.0, -0.5, 0.5, 1.0], id: \.self) { tick in
                            Capsule()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 1.5, height: 10)
                                .offset(x: tick * (w / 2 - 2))
                        }
                        Capsule()
                            .fill(inTune ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                            .frame(width: 4, height: 26)
                            .offset(x: position * (w / 2 - 2))
                            .opacity(hasNote ? 1 : 0)
                            // A spring with no bounce: it retargets smoothly as readings arrive,
                            // so the needle glides instead of stepping.
                            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: position)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 28)
                .accessibilityHidden(true)

                HStack {
                    Text("Flat")
                    Spacer()
                    Text(verbatim: statusText(display))
                        .fontWeight(.medium)
                        .foregroundStyle(inTune ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text("Sharp")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Stepper(value: Binding(get: { store.tuner?.referenceHz ?? 440 }, set: { store.setTunerReference($0) }), in: 430...450) {
                    LabeledContent("Reference Pitch") {
                        Text(verbatim: "\(store.tuner?.referenceHz ?? 440) Hz").monospacedDigit()
                    }
                }
                .fixedSize()
                Spacer()
                Button("Done") { store.setTuner(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func centsText(_ cents: Double) -> String {
        let rounded = Int(cents.rounded())
        if rounded == 0 { return String(localized: "0 cents") }
        // A real minus sign, and an explicit plus, so flat and sharp read at a glance.
        return String(localized: "\(rounded > 0 ? "+" : "−")\(abs(rounded)) cents")
    }

    private func statusText(_ display: TunerFilter) -> String {
        if store.tuner == nil { return String(localized: "Starting…") }
        if display.note == nil { return String(localized: "Play one string") }
        if display.inTune { return String(localized: "In Tune") }
        return display.cents < 0 ? String(localized: "Tune Up") : String(localized: "Tune Down")
    }
}
