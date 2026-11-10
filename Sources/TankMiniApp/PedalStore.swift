import AppKit
import Foundation
import SwiftUI
import TankMiniCore
import UniformTypeIdentifiers

/// Owns the pedal link. All pedal traffic runs on one serial queue, off the main thread.
final class PedalIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tankmini.io", qos: .userInitiated)
    private var pedal: Pedal?

    func run<T>(_ work: @escaping (Pedal) throws -> T, then: @escaping @MainActor (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error>
            do {
                if self.pedal == nil { self.pedal = try Pedal() }
                result = .success(try work(self.pedal!))
            } catch {
                // A refused command leaves the link usable; anything else means it is gone.
                switch error {
                case LinkError.rejected, LinkError.unexpectedReply: break
                default: self.pedal = nil
                }
                result = .failure(error)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
    }

    /// Blocking variant used only while quitting.
    func runAndWait(_ work: @escaping (Pedal) throws -> Void) {
        queue.sync { if let pedal = self.pedal { try? work(pedal) } }
    }
}

struct PedalSnapshot {
    var firmware: String
    var globals: Globals
    var patch: Patch
    var stored: [Patch]
    var amps: [String]
    var cabs: [String]
}

@MainActor
final class PedalStore: ObservableObject {
    enum Connection: Equatable {
        case searching
        case connected(firmware: String)
        case demo
    }

    @Published var connection: Connection = .searching
    @Published var patch: Patch?
    @Published var stored: [Patch] = []
    @Published var activeSlot = 0
    @Published var bypassed = false
    @Published var loopback = false
    @Published var ampNames: [String] = []
    @Published var cabNames: [String] = []
    @Published var selected: Module = .amp
    @Published var notice: String?
    @Published var saving = false
    @Published var tunerOn = false
    @Published var tuner: TunerReading?

    /// Settings the pedal loaded when a module's model was last changed in this session,
    /// kept so a knob can be reset even when the model differs from the saved preset.
    private var modelDefaults: [Int: (unit: Int, raw: [UInt8])] = [:]

    let isDemo: Bool
    private let io = PedalIO()
    private var pollTimer: Timer?
    private var tunerTimer: Timer?
    private var tunerRequestInFlight = false
    private var pollInFlight = false
    private var lastEdit = Date.distantPast

    private struct PendingOp {
        var key: String
        var work: (Pedal) throws -> [UInt8]?
        var apply: (@MainActor ([UInt8]?) -> Void)?
    }
    private var pending: [PendingOp] = []
    private var draining = false

    init(demo: Bool) {
        isDemo = demo
        if demo {
            loadDemo()
        } else {
            poll()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    // MARK: derived state

    var isConnected: Bool { connection != .searching }

    var isDirty: Bool {
        guard let patch, stored.indices.contains(activeSlot) else { return false }
        return patch != stored[activeSlot]
    }

    func deviceNames(_ module: Module) -> [String] {
        module == .amp ? ampNames : module == .cab ? cabNames : []
    }

    func modelName(_ module: Module, in patch: Patch) -> String {
        Catalog.modelName(module, unit: patch.unit(module.rawValue), deviceNames: deviceNames(module))
    }

    // MARK: connection + polling

    private func poll() {
        guard !isDemo, !pollInFlight, !saving else { return }
        if !isConnected {
            pollInFlight = true
            io.run({ pedal -> PedalSnapshot in
                let globals = try pedal.globals()
                let amps = try pedal.modelNames(.amp)
                let cabs = try pedal.modelNames(.cab)
                let patch = try pedal.editBuffer()
                let stored = try (0..<Bank.slots).map { try pedal.storedPatch($0) }
                return PedalSnapshot(firmware: pedal.firmware, globals: globals, patch: patch, stored: stored, amps: amps, cabs: cabs)
            }, then: { [weak self] result in
                guard let self else { return }
                self.pollInFlight = false
                if case .success(let snap) = result { self.apply(snap) }
            })
            return
        }
        // Follow the footswitches and any change made on the pedal itself.
        guard isIdle else { return }
        pollInFlight = true
        io.run({ pedal in (try pedal.globals(), try pedal.editBuffer()) }, then: { [weak self] result in
            guard let self else { return }
            self.pollInFlight = false
            switch result {
            case .success(let (globals, live)):
                guard self.isIdle else { return }
                self.activeSlot = min(globals.activeSlot, Bank.slots - 1)
                self.bypassed = globals.bypassed
                if self.patch != live { self.patch = live }
            case .failure(let error):
                self.handle(error)
            }
        })
    }

    private var isIdle: Bool {
        pending.isEmpty && !draining && !saving && Date().timeIntervalSince(lastEdit) > 0.6
    }

    private func apply(_ snap: PedalSnapshot) {
        connection = .connected(firmware: snap.firmware)
        activeSlot = min(snap.globals.activeSlot, Bank.slots - 1)
        bypassed = snap.globals.bypassed
        ampNames = snap.amps
        cabNames = snap.cabs
        stored = snap.stored
        patch = snap.patch
        notice = nil
        Backups.saveIfChanged(bank: snap.stored.flatMap(\.bytes) + Bank.trailer)
    }

    private func handle(_ error: Error) {
        switch error {
        case LinkError.rejected, LinkError.unexpectedReply:
            notice = error.localizedDescription
        default:
            // Unplugged or powered off: go back to waiting for it.
            connection = .searching
            patch = nil
            pending.removeAll()
            tunerOn = false
            tunerTimer?.invalidate()
        }
    }

    func reload() {
        guard !isDemo else { return }
        connection = .searching
        poll()
    }

    // MARK: serialised live edits

    /// Queue a write. A newer write with the same key replaces one still waiting, so a
    /// dragged knob only ever sends its most recent value.
    private func enqueue(_ key: String, apply: (@MainActor ([UInt8]?) -> Void)? = nil, _ work: @escaping (Pedal) throws -> [UInt8]?) {
        lastEdit = Date()
        if isDemo { apply?(nil); return }
        let op = PendingOp(key: key, work: work, apply: apply)
        if let i = pending.firstIndex(where: { $0.key == key }) { pending[i] = op } else { pending.append(op) }
        drain()
    }

    private func drain() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        let batch = pending
        pending = []
        io.run({ pedal in try batch.map { try $0.work(pedal) } }, then: { [weak self] result in
            guard let self else { return }
            self.draining = false
            self.lastEdit = Date()
            switch result {
            case .success(let outputs):
                for (op, out) in zip(batch, outputs) { op.apply?(out) }
            case .failure(let error):
                self.handle(error)
            }
            self.drain()
        })
    }

    // MARK: editing the playing patch (not stored until Save)

    func setParam(_ module: Module, _ index: Int, _ value: Int) {
        guard var p = patch, p.param(module.rawValue, index) != value else { return }
        p.setParam(module.rawValue, index, value)
        patch = p
        enqueue("param:\(module.rawValue):\(index)") { try $0.setParam(module: module.rawValue, index: index, value: value); return nil }
    }

    /// Put one setting back: to the saved preset's value when the model is the saved one,
    /// otherwise to the value the pedal loaded for the current model.
    func resetParam(_ module: Module, _ index: Int) {
        guard let p = patch else { return }
        let m = module.rawValue
        if stored.indices.contains(activeSlot), stored[activeSlot].unit(m) == p.unit(m) {
            setParam(module, index, stored[activeSlot].param(m, index))
        } else if let defaults = modelDefaults[m], defaults.unit == p.unit(m), defaults.raw.count == 12 {
            let value = Int(Int16(bitPattern: UInt16(defaults.raw[index * 2]) | UInt16(defaults.raw[index * 2 + 1]) << 8))
            setParam(module, index, value)
        }
    }

    func setEnabled(_ module: Module, _ on: Bool) {
        guard var p = patch, p.isOn(module.rawValue) != on else { return }
        p.setOn(module.rawValue, on)
        patch = p
        enqueue("enable:\(module.rawValue)") { try $0.setEnabled(module: module.rawValue, on); return nil }
    }

    func setUnit(_ module: Module, _ unit: Int) {
        guard var p = patch, p.unit(module.rawValue) != unit else { return }
        p.setUnit(module.rawValue, unit)
        patch = p
        enqueue("unit:\(module.rawValue)", apply: { [weak self] raw in
            // The pedal loads the new model's default settings; show them.
            guard let self, let raw, var p = self.patch, p.unit(module.rawValue) == unit else { return }
            self.modelDefaults[module.rawValue] = (unit, raw)
            p.setParams(module.rawValue, raw: raw)
            self.patch = p
        }) { try $0.setUnit(module: module.rawValue, unit) }
    }

    func setVolume(_ value: Int) {
        guard var p = patch, p.volume != value else { return }
        p.volume = value
        patch = p
        enqueue("volume") { try $0.setVolume(value); return nil }
    }

    func setChain(_ chain: [Int]) {
        guard var p = patch, p.chain != chain, Set(chain) == Set(0..<6) else { return }
        p.chain = chain
        patch = p
        enqueue("chain") { try $0.setChain(chain); return nil }
    }

    /// Move a module one step earlier (-1) or later (+1) in the signal chain.
    func move(_ module: Module, by step: Int) {
        guard let p = patch, let i = p.chain.firstIndex(of: module.rawValue) else { return }
        let j = i + step
        guard p.chain.indices.contains(j) else { return }
        var chain = p.chain
        chain.swapAt(i, j)
        setChain(chain)
    }

    /// Drop `module` at the position currently held by `target`.
    func move(_ module: Module, before target: Module) {
        guard let p = patch, module != target,
              let from = p.chain.firstIndex(of: module.rawValue),
              let to = p.chain.firstIndex(of: target.rawValue) else { return }
        var chain = p.chain
        chain.remove(at: from)
        chain.insert(module.rawValue, at: to)
        setChain(chain)
    }

    func setBypass(_ on: Bool) {
        guard bypassed != on else { return }
        bypassed = on
        enqueue("bypass") { try $0.setBypass(on); return nil }
    }

    func setLoopback(_ on: Bool) {
        guard loopback != on else { return }
        loopback = on
        enqueue("loopback") { try $0.setLoopback(on); return nil }
    }

    // MARK: presets

    /// Switch to another preset. Unsaved edits to the current one are dropped by the pedal.
    func select(_ slot: Int) {
        guard (0..<Bank.slots).contains(slot) else { return }
        pending.removeAll()
        modelDefaults.removeAll()
        lastEdit = Date()
        if isDemo {
            activeSlot = slot
            patch = stored[slot]
            return
        }
        activeSlot = slot
        if stored.indices.contains(slot) { patch = stored[slot] }
        io.run({ pedal -> (Globals, Patch) in
            try pedal.selectSlot(slot)
            Thread.sleep(forTimeInterval: 0.1)
            return (try pedal.globals(), try pedal.editBuffer())
        }, then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (globals, live)):
                self.activeSlot = min(globals.activeSlot, Bank.slots - 1)
                self.patch = live
            case .failure(let error):
                self.handle(error)
            }
        })
    }

    func revert() { select(activeSlot) }

    /// Store the playing patch in `slot` permanently (writes the pedal's flash memory).
    func save(to slot: Int) {
        guard let patch, (0..<Bank.slots).contains(slot), !saving else { return }
        if isDemo {
            stored[slot] = patch
            activeSlot = slot
            return
        }
        saving = true
        pending.removeAll()
        io.run({ pedal -> (Globals, Patch) in
            try pedal.save(patch, to: slot)
            return (try pedal.globals(), try pedal.editBuffer())
        }, then: { [weak self] result in
            guard let self else { return }
            self.saving = false
            switch result {
            case .success(let (globals, live)):
                self.stored[slot] = patch
                self.activeSlot = min(globals.activeSlot, Bank.slots - 1)
                self.patch = live
                self.notice = nil
            case .failure(let error):
                self.notice = String(localized: "Save failed: \(error.localizedDescription)")
                self.handle(error)
            }
        })
    }

    // MARK: tuner

    func setTuner(_ on: Bool) {
        guard tunerOn != on else { return }
        tunerOn = on
        tuner = nil
        tunerTimer?.invalidate()
        if isDemo {
            if on { tuner = TunerReading(bypassVolume: 0, referenceHz: 440, running: true, note: 8, silent: false, deviation: 121) }
            return
        }
        io.run({ try $0.setTuner(on) }, then: { [weak self] result in
            if case .failure(let error) = result { self?.handle(error) }
        })
        guard on else { return }
        tunerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tunerOn, !self.tunerRequestInFlight else { return }
                self.tunerRequestInFlight = true
                self.io.run({ try $0.tuner() }, then: { [weak self] result in
                    guard let self else { return }
                    self.tunerRequestInFlight = false
                    if case .success(let reading) = result, self.tunerOn { self.tuner = reading }
                })
            }
        }
    }

    func setTunerReference(_ hz: Int) {
        let clamped = min(max(hz, 430), 450)
        tuner?.referenceHz = clamped
        enqueue("tuner-ref") { try $0.setTunerReference(clamped); return nil }
    }

    /// Leave the pedal in a normal state when the app quits.
    func shutdown() {
        guard !isDemo, tunerOn else { return }
        io.runAndWait { try $0.setTuner(false) }
    }

    // MARK: files

    static let patchType = UTType(filenameExtension: "tkm") ?? .data
    static let bankType = UTType(filenameExtension: "atkm") ?? .data

    func exportPatch() {
        guard let patch else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [PedalStore.patchType]
        panel.nameFieldStringValue = "Tank Mini \(Bank.slotName(activeSlot)).tkm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(patch.bytes).write(to: url) } catch { notice = error.localizedDescription }
    }

    func exportBank() {
        guard stored.count == Bank.slots else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [PedalStore.bankType]
        panel.nameFieldStringValue = "Tank Mini presets.atkm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(stored.flatMap(\.bytes) + Bank.trailer).write(to: url) } catch { notice = error.localizedDescription }
    }

    /// Load a preset file into the playing patch to audition it. Nothing is stored until Save.
    /// A whole-bank file (.atkm) contributes its preset for the slot that is active now.
    func importPatch() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [PedalStore.patchType, PedalStore.bankType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var bytes = [UInt8](data)
        if bytes.count == Bank.size {
            bytes = Array(bytes[(activeSlot * Patch.size)..<((activeSlot + 1) * Patch.size)])
        }
        guard let imported = Patch(bytes: bytes), isPlausible(imported) else {
            notice = String(localized: "That file is not a Tank Mini preset.")
            return
        }
        patch = imported
        enqueue("load") { try $0.loadIntoEditBuffer(imported); return nil }
    }

    private func isPlausible(_ p: Patch) -> Bool {
        let raw = p.bytes[Patch.Offset.chain..<(Patch.Offset.chain + 6)].map(Int.init)
        guard Set(raw) == Set(0..<6), (0...100).contains(p.volume) else { return false }
        return Module.allCases.allSatisfy { p.unit($0.rawValue) < Catalog.modelCount($0) }
    }

    // MARK: demo data (no pedal attached)

    private func loadDemo() {
        connection = .demo
        ampNames = ["UWE-Twins", "UK-C30Normal", "MarsVM410", "Victor_Mars", "BritPLEX_100", "MarsFD100", "Eagle_SAVAGE",
                    "TH_DieselHgn", "PvEV5150", "FORTIN_CALI", "MESS_MktCln2", "CA-tweed", "BogSV20", "JUICE_JIM",
                    "Sur_SL68", "BassADAtube", "BassAlmbic", "BassG800K_7", "BassTR-Trad", "BassMarkT501"]
        cabNames = ["EAGLProV30s", "Sperimental", "JUICE4x12V30", "Mess Bog", "FdChamp", "FdPrJunir", "Mar960BV30",
                    "DizzlV30", "Electrovoice", "MessDRectV30", "TwinJensenC", "TwedDlx1X12", "FendShowman", "J120Rolnd",
                    "UK-C30Silvers", "BassAgula25", "BassJensen10", "BassFdBassman", "BassAmpg410", "BassEDN300"]
        stored = (0..<Bank.slots).map { slot in
            var p = Patch(bytes: [UInt8](repeating: 0, count: Patch.size))!
            p.volume = 70 + slot % 20
            p.chain = [0, 1, 2, 3, 4, 5]
            for m in Module.allCases {
                p.setOn(m.rawValue, m == .amp || m == .cab || (slot + m.rawValue) % 3 == 0)
                p.setUnit(m.rawValue, (slot * (m.rawValue + 2)) % Catalog.modelCount(m))
                for i in 0..<Patch.paramsPerModule { p.setParam(m.rawValue, i, (slot * 7 + m.rawValue * 13 + i * 17 + 20) % 101) }
            }
            return p
        }
        activeSlot = 4
        var live = stored[4]
        live.setParam(Module.amp.rawValue, 0, 62)
        patch = live
    }
}

/// Keeps a copy of the pedal's presets on this Mac each time they are found changed,
/// so a preset overwritten by mistake can be brought back.
enum Backups {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TankMini/Backups", isDirectory: true)
    }

    static func saveIfChanged(bank: [UInt8]) {
        guard bank.count == Bank.size else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "atkm" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        if let last = existing.last, let data = try? Data(contentsOf: last), [UInt8](data) == bank { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("Presets \(stamp.string(from: Date())).atkm")
        try? Data(bank).write(to: url)
    }
}
