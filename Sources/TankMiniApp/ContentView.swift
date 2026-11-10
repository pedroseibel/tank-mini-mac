import SwiftUI
import TankMiniCore

struct ContentView: View {
    @EnvironmentObject var store: PedalStore
    @EnvironmentObject var audio: AudioSetup

    // Declared without the @State attribute: on this SDK it is a compiler macro whose plugin
    // ships only with full Xcode, and this project builds with the Command Line Tools alone.
    private var pendingSlotStorage = State<Int?>(initialValue: nil)
    private var pendingSlot: Int? {
        get { pendingSlotStorage.wrappedValue }
        nonmutating set { pendingSlotStorage.wrappedValue = newValue }
    }
    private var saveTargetStorage = State<Int?>(initialValue: nil)
    private var saveTarget: Int? {
        get { saveTargetStorage.wrappedValue }
        nonmutating set { saveTargetStorage.wrappedValue = newValue }
    }

    var body: some View {
        NavigationSplitView {
            PresetSidebar(onSelect: requestSelect)
                .navigationSplitViewColumnWidth(min: 190, ideal: 216, max: 300)
        } detail: {
            DetailView(onSaveTo: { saveTarget = $0 })
        }
        .sheet(isPresented: Binding(get: { store.tunerOn }, set: { if !$0 { store.setTuner(false) } })) {
            TunerView()
        }
        .confirmationDialog("Switch presets without saving?",
                            isPresented: Binding(get: { pendingSlot != nil }, set: { if !$0 { pendingSlot = nil } }),
                            presenting: pendingSlot) { slot in
            Button("Switch to \(Bank.slotName(slot))", role: .destructive) { store.select(slot) }
            Button("Keep Editing", role: .cancel) {}
        } message: { _ in
            Text("Your changes to \(Bank.slotName(store.activeSlot)) have not been saved to the pedal and will be lost.")
        }
        .confirmationDialog("Replace preset \(saveTarget.map(Bank.slotName) ?? "")?",
                            isPresented: Binding(get: { saveTarget != nil }, set: { if !$0 { saveTarget = nil } }),
                            presenting: saveTarget) { slot in
            Button("Replace \(Bank.slotName(slot))", role: .destructive) { store.save(to: slot) }
            Button("Cancel", role: .cancel) {}
        } message: { slot in
            Text("The sound you hear now will be stored in \(Bank.slotName(slot)) on the pedal. A copy of your presets from before this session is kept on this Mac.")
        }
    }

    private func requestSelect(_ slot: Int) {
        if slot == store.activeSlot { return }
        if store.isDirty { pendingSlot = slot } else { store.select(slot) }
    }
}

// MARK: - Sidebar

struct PresetSidebar: View {
    @EnvironmentObject var store: PedalStore
    let onSelect: (Int) -> Void

    var body: some View {
        List(selection: Binding<Int?>(get: { store.patch == nil ? nil : store.activeSlot },
                                      set: { if let slot = $0 { onSelect(slot) } })) {
            // Section and row identities must not overlap: rows are identified by slot number
            // (0...20), sections by a string, or the list confuses a bank header with a preset.
            ForEach((0..<7).map { "bank-\($0)" }, id: \.self) { sectionID in
                let bank = Int(sectionID.dropFirst(5)) ?? 0
                Section {
                    ForEach(Array((bank * 3)..<(bank * 3 + 3)), id: \.self) { slot in
                        PresetRow(slot: slot).tag(slot)
                    }
                } header: {
                    Text("Bank \(bank + 1)")
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(store.stored.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionStatus()
        }
    }
}

struct PresetRow: View {
    @EnvironmentObject var store: PedalStore
    let slot: Int

    var body: some View {
        let patch = store.stored.indices.contains(slot) ? store.stored[slot] : nil
        let edited = slot == store.activeSlot && store.isDirty
        HStack(spacing: 8) {
            Text(Bank.slotName(slot))
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 24, alignment: .leading)
            Text(patch.map { store.modelName(.amp, in: $0) } ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if edited {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .help("Edited, not saved to the pedal")
                    .accessibilityLabel("Edited")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preset \(Bank.slotName(slot))")
    }
}

struct ConnectionStatus: View {
    @EnvironmentObject var store: PedalStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch store.connection {
        case .searching: return String(localized: "Not Connected")
        case .connected: return "Tank Mini"
        case .demo: return String(localized: "Demo")
        }
    }

    private var detail: String {
        switch store.connection {
        case .searching: return String(localized: "Looking for the pedal…")
        case .connected(let firmware): return String(localized: "USB · Firmware \(firmware.replacingOccurrences(of: "TANK MINI_", with: ""))")
        case .demo: return String(localized: "Sample data, no pedal")
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var store: PedalStore
    let onSaveTo: (Int) -> Void

    var body: some View {
        Group {
            if let patch = store.patch {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let notice = store.notice {
                            NoticeBanner(text: notice)
                        }
                        ChainSection(patch: patch)
                        ModuleInspector(patch: patch, module: store.selected)
                        VolumeRow(patch: patch)
                    }
                    .padding(24)
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("Connect Your Tank Mini", systemImage: "cable.connector")
                } description: {
                    Text("Plug the pedal into this Mac with a USB cable and switch it on. It is picked up automatically.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AudioBar()
        }
        .navigationTitle(store.patch == nil ? "Tank Mini" : String(localized: "Preset \(Bank.slotName(store.activeSlot))"))
        .navigationSubtitle(subtitle)
        .toolbar {
            // Each control is its own toolbar item with a fixed spacer between neighbours,
            // so no two controls touch.
            ToolbarItem(placement: .primaryAction) {
                Button { store.setTuner(true) } label: { ToolbarLabel(title: "Tuner", symbol: "tuningfork") }
                    .help("Tune your instrument")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { store.bypassed }, set: { store.setBypass($0) })) {
                    ToolbarLabel(title: "Bypass", symbol: "arrow.triangle.branch")
                }
                .help("Pass the dry signal through, skipping every effect")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { store.loopback }, set: { store.setLoopback($0) })) {
                    ToolbarLabel(title: "Loopback", symbol: "arrow.triangle.2.circlepath")
                }
                .help("Mix audio played by this Mac into what the pedal records over USB")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.revert() } label: { Text("Revert").padding(.horizontal, 4) }
                    .disabled(!store.isDirty)
                    .help("Discard your changes and reload this preset from the pedal")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.save(to: store.activeSlot) } label: {
                    Text(store.saving ? LocalizedStringKey("Saving…") : LocalizedStringKey("Save")).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isDirty || store.saving)
                .keyboardShortcut("s", modifiers: .command)
                .help("Store this sound in preset \(Bank.slotName(store.activeSlot)) on the pedal")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu("Save To") {
                        ForEach(0..<Bank.slots, id: \.self) { slot in
                            Button(slot == store.activeSlot ? String(localized: "\(Bank.slotName(slot)) (Current)") : Bank.slotName(slot)) {
                                if slot == store.activeSlot { store.save(to: slot) } else { onSaveTo(slot) }
                            }
                        }
                    }
                    Divider()
                    Button("Export Preset…") { store.exportPatch() }
                    Button("Export All Presets…") { store.exportBank() }
                    Button("Load Preset From File…") { store.importPatch() }
                    Divider()
                    Button("Show Preset Backups in Finder") {
                        try? FileManager.default.createDirectory(at: Backups.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Backups.folder)
                    }
                    Button("Reload From Pedal") { store.reload() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Save to another preset, export, import")
            }
        }
        .disabled(store.patch == nil && store.isConnected)
    }

    private var subtitle: String {
        guard let patch = store.patch else { return "" }
        let models = "\(store.modelName(.amp, in: patch)) · \(store.modelName(.cab, in: patch))"
        return store.isDirty ? String(localized: "\(models) — Edited") : models
    }
}

/// Icon and title for a toolbar control, with the gap and insets set explicitly: the stock
/// title-and-icon label style leaves an uneven gap in a window toolbar.
struct ToolbarLabel: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.medium)
            Text(title)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    @EnvironmentObject var store: PedalStore
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout)
            Spacer()
            Button("Dismiss") { store.notice = nil }.controlSize(.small)
        }
        .padding(10)
        .background(Metrics.groupFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Signal chain

struct ChainSection: View {
    @EnvironmentObject var store: PedalStore
    let patch: Patch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Signal Chain").font(.headline)
                Spacer()
                Text("Drag a block to change the order").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(patch.chain, id: \.self) { id in
                    let module = Module(rawValue: id)!
                    if id != patch.chain.first {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    ChainTile(patch: patch, module: module)
                        .draggable(String(module.rawValue))
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first.flatMap(Int.init), let dragged = Module(rawValue: raw) else { return false }
                            store.move(dragged, before: module)
                            return true
                        }
                }
            }
            .layoutSpring(value: patch.chain)
        }
    }
}

struct ChainTile: View {
    @EnvironmentObject var store: PedalStore
    let patch: Patch
    let module: Module

    var body: some View {
        let on = patch.isOn(module.rawValue)
        let selected = store.selected == module
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ModuleBadge(module: module, size: 24, active: on)
                Spacer(minLength: 0)
                Toggle("\(module.localizedTitle) on", isOn: Binding(get: { on }, set: { store.setEnabled(module, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(module.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? .primary : .secondary)
                Text(store.modelName(module, in: patch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Metrics.groupFill), in: shape)
        // The ring is a state border (selection), so it stays a border; unselected tiles have none.
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
        .animation(.easeOut(duration: 0.15), value: selected)
        .contentShape(shape)
        .onTapGesture { store.selected = module }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(module.localizedTitle), \(store.modelName(module, in: patch))"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Selected module

struct ModuleInspector: View {
    @EnvironmentObject var store: PedalStore
    let patch: Patch
    let module: Module

    var body: some View {
        let id = module.rawValue
        let on = patch.isOn(id)
        let unit = patch.unit(id)
        let names = Catalog.paramNames(module, unit: unit)
        let position = patch.chain.firstIndex(of: id) ?? 0

        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ModuleBadge(module: module, size: 32, active: on)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(module.localizedTitle).font(.title3.weight(.semibold))
                        Text("Position \(position + 1) of 6").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Model", selection: Binding(get: { unit }, set: { store.setUnit(module, $0) })) {
                        ForEach(0..<Catalog.modelCount(module), id: \.self) { u in
                            Text(Catalog.modelName(module, unit: u, deviceNames: store.deviceNames(module))).tag(u)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 8)

                    Spacer(minLength: 12)

                    ControlGroup {
                        Button { store.move(module, by: -1) } label: { Label("Move Earlier", systemImage: "chevron.left") }
                            .disabled(position == 0)
                            .help("Move earlier in the signal chain")
                        Button { store.move(module, by: 1) } label: { Label("Move Later", systemImage: "chevron.right") }
                            .disabled(position == 5)
                            .help("Move later in the signal chain")
                    }
                    .labelStyle(.iconOnly)
                    .fixedSize()

                    Toggle("\(module.localizedTitle) on", isOn: Binding(get: { on }, set: { store.setEnabled(module, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                ModelNoteView(module: module, modelName: store.modelName(module, in: patch))

                if names.isEmpty {
                    Text("This model has no settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                            let value = patch.param(id, index)
                            Knob(label: L(name),
                                 value: value,
                                 display: Catalog.formatted(name, module: module, value: value),
                                 enabled: on,
                                 onReset: { store.resetParam(module, index) }) { store.setParam(module, index, $0) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
        }
    }
}

/// What the selected model is: the gear it appears to be based on and how it sounds.
struct ModelNoteView: View {
    let module: Module
    let modelName: String

    var body: some View {
        let note = ModelGuide.note(module: module, modelName: modelName)
        if note.headline != nil || !note.detail.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let headline = note.headline {
                        Text(verbatim: headline).fontWeight(.medium)
                    }
                    Text(verbatim: note.detail).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var store: PedalStore
    let patch: Patch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preset Volume").font(.headline)
            HStack(spacing: 12) {
                Slider(value: Binding(get: { Double(patch.volume) }, set: { store.setVolume(Int($0.rounded())) }), in: 0...100) {
                    Text("Preset Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .labelsHidden()
                Text("\(patch.volume)")
                    .font(.body.weight(.medium).monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}

// MARK: - Audio interface bar

struct AudioBar: View {
    @EnvironmentObject var audio: AudioSetup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(audio.error ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if audio.combinedExists {
                Button("Remove Combined Device") { audio.removeCombinedDevice() }
            } else {
                Button("Create Combined Device") { audio.createCombinedDevice() }
                    .disabled(!audio.bothPresent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var icon: String {
        if audio.combinedExists { return "checkmark.circle.fill" }
        return audio.bothPresent ? "exclamationmark.triangle.fill" : "cable.connector"
    }

    private var iconColor: Color {
        if audio.combinedExists { return .green }
        return audio.bothPresent ? .yellow : .secondary
    }

    private var title: String {
        if audio.combinedExists { return String(localized: "Audio interface ready") }
        if audio.bothPresent { return String(localized: "macOS lists the pedal as two audio devices") }
        return String(localized: "Audio not connected")
    }

    private var detail: String {
        if audio.combinedExists {
            return String(localized: "Choose “\(AudioSetup.combinedName)” as input and output in your recording app. 2 in, 2 out, 44.1 kHz.")
        }
        if audio.bothPresent {
            return String(localized: "Both are named “USB-Audio”. Combine them into one “\(AudioSetup.combinedName)” device that apps can use for input and output.")
        }
        return String(localized: "macOS can’t see the pedal’s USB audio right now.")
    }
}
