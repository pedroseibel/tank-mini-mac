import SwiftUI
import TankMiniCore

struct TunerView: View {
    @EnvironmentObject var store: PedalStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reading = store.tuner
        let offset = reading.flatMap { $0.note == nil ? nil : Double($0.deviation - 127) }
        let inTune = reading?.inTune ?? false

        VStack(spacing: 20) {
            Text(reading?.noteName ?? "–")
                .font(.system(size: 88, weight: .semibold, design: .rounded))
                .foregroundStyle(inTune ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .frame(height: 96)
                .accessibilityLabel(Text(verbatim: reading?.noteName.map { String(localized: "Note \($0)") } ?? String(localized: "No note")))

            VStack(spacing: 8) {
                // Deviation meter: centre is in tune, left is flat, right is sharp.
                GeometryReader { geo in
                    let w = geo.size.width
                    let clamped = min(max((offset ?? 0) / 60, -1), 1)
                    ZStack {
                        Capsule().fill(Color.primary.opacity(0.10)).frame(height: 4)
                        Capsule().fill(Color.green.opacity(0.35)).frame(width: w * 0.15, height: 4)
                        if offset != nil {
                            Capsule()
                                .fill(inTune ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                                .frame(width: 4, height: 22)
                                .offset(x: clamped * (w / 2 - 2))
                                // The needle is a live meter: follow the reading closely, never lag it.
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: clamped)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 24)
                .accessibilityHidden(true)

                HStack {
                    Text("Flat")
                    Spacer()
                    Text(verbatim: statusText(reading, inTune: inTune))
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
                Stepper(value: Binding(get: { reading?.referenceHz ?? 440 }, set: { store.setTunerReference($0) }), in: 430...450) {
                    LabeledContent("Reference Pitch") {
                        Text("\(reading?.referenceHz ?? 440) Hz").monospacedDigit()
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

    private func statusText(_ reading: TunerReading?, inTune: Bool) -> String {
        guard let reading else { return String(localized: "Starting…") }
        if reading.note == nil { return String(localized: "Play one string") }
        if inTune { return String(localized: "In Tune") }
        return reading.deviation < 127 ? String(localized: "Tune Up") : String(localized: "Tune Down")
    }
}
