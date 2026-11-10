import Foundation

public struct Globals: Equatable {
    public var activeSlot: Int
    public var bypassed: Bool
    public var raw: [UInt8]
}

public struct TunerReading: Equatable {
    public var bypassVolume: Int
    public var referenceHz: Int
    public var running: Bool
    /// 0 = G#, 1 = A ... 11 = G; nil when there is no stable note.
    public var note: Int?
    public var silent: Bool
    /// Raw deviation, 127 = in tune, lower = flat.
    public var deviation: Int

    public init(bypassVolume: Int, referenceHz: Int, running: Bool, note: Int?, silent: Bool, deviation: Int) {
        self.bypassVolume = bypassVolume
        self.referenceHz = referenceHz
        self.running = running
        self.note = note
        self.silent = silent
        self.deviation = deviation
    }

    public static let noteNames = ["G♯", "A", "A♯", "B", "C", "C♯", "D", "D♯", "E", "F", "F♯", "G"]
    public var noteName: String? { note.map { TunerReading.noteNames[$0] } }
    public var inTune: Bool { note != nil && (118...136).contains(deviation) }
}

/// High-level commands. All calls block until the pedal answers; call them off the main thread.
public final class Pedal {
    public let link: MIDILink

    /// Firmware name reported during the opening handshake, e.g. "TANK MINI_004".
    public private(set) var firmware = ""

    public init() throws {
        link = try MIDILink()
        // CoreMIDI needs a moment after the ports are connected before traffic flows,
        // so the opening handshake retries the identity query a few times.
        var lastError: Error = LinkError.timeout
        for attempt in 0..<8 {
            do {
                firmware = try identity(timeout: 0.25)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
            }
        }
        throw lastError
    }

    // MARK: raw access

    public func identity(timeout: TimeInterval = 1.0) throws -> String {
        let reply = try link.transact(Frame(cmd: Command.identity), timeout: timeout)
        guard reply.cmd == Command.identity else { throw LinkError.unexpectedReply(reply.bytes.hex) }
        let name = reply.body.prefix { $0 != 0 }
        return String(decoding: name, as: UTF8.self)
    }

    private func header(_ region: Region, _ addr: UInt32, _ len: Int) -> [UInt8] {
        [region.rawValue,
         UInt8(addr & 0xff), UInt8((addr >> 8) & 0xff), UInt8((addr >> 16) & 0xff), UInt8((addr >> 24) & 0xff),
         UInt8(len & 0xff), UInt8((len >> 8) & 0xff), UInt8((len >> 16) & 0xff)]
    }

    public func read(_ region: Region, _ addr: UInt32, _ len: Int) throws -> [UInt8] {
        let head = header(region, addr, len)
        let reply = try link.transact(Frame(cmd: Command.read, body: head))
        if reply.cmd == Command.ack { throw LinkError.rejected(reply.body.first ?? 0xff) }
        guard reply.cmd == Command.read, reply.body.count == head.count + len, Array(reply.body.prefix(head.count)) == head else {
            throw LinkError.unexpectedReply(reply.bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        return Array(reply.body.dropFirst(head.count))
    }

    public func write(_ region: Region, _ addr: UInt32, _ data: [UInt8]) throws {
        let reply = try link.transact(Frame(cmd: Command.write, body: header(region, addr, data.count) + data))
        guard reply.cmd == Command.ack else { throw LinkError.unexpectedReply(reply.bytes.hex) }
        guard reply.body.first == 0 else { throw LinkError.rejected(reply.body.first ?? 0xff) }
    }

    // MARK: state

    public func globals() throws -> Globals {
        let g = try read(.dev, Address.glob, 4)
        return Globals(activeSlot: Int(g[0]), bypassed: g[2] != 0, raw: g)
    }

    /// The patch that is playing right now, including unsaved edits.
    public func editBuffer() throws -> Patch {
        guard let p = Patch(bytes: try read(.dev, Address.editBuffer, Patch.size)) else {
            throw LinkError.unexpectedReply("short patch")
        }
        return p
    }

    public func storedPatch(_ slot: Int) throws -> Patch {
        guard let p = Patch(bytes: try read(.dev, Address.presetTable + UInt32(slot * Patch.size), Patch.size)) else {
            throw LinkError.unexpectedReply("short patch")
        }
        return p
    }

    /// All 21 stored presets in the official .atkm layout (1942 bytes).
    public func bank() throws -> [UInt8] {
        var out: [UInt8] = []
        for slot in 0..<Bank.slots { out += try storedPatch(slot).bytes }
        return out + Bank.trailer
    }

    public func modelNames(_ module: Module) throws -> [String] {
        let addr = module == .amp ? Address.ampNames : Address.cabNames
        // 20 names x 14 bytes. Must be one read from the base address: the pedal
        // ignores the low address bits here and always serves the table from its start.
        let raw = try read(.usr, addr, 280)
        return stride(from: 0, to: 280, by: 14).map { i in
            String(decoding: raw[i..<(i + 14)].prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: live editing (edit buffer only; nothing is stored until `save`)

    public func setParam(module: Int, index: Int, value: Int) throws {
        try write(.dev, Address.editBuffer + UInt32(Patch.Offset.param(module, index)), Patch.word(value))
    }

    public func setEnabled(module: Int, _ on: Bool) throws {
        try write(.dev, Address.editBuffer + UInt32(Patch.Offset.enabled + module), [on ? 1 : 0])
    }

    /// Change a module's model. The pedal loads that model's defaults; they are returned (12 raw bytes).
    public func setUnit(module: Int, _ unit: Int) throws -> [UInt8] {
        try write(.dev, Address.editBuffer + UInt32(Patch.Offset.unit + module), [UInt8(clamping: unit)])
        Thread.sleep(forTimeInterval: 0.1)
        return try read(.dev, Address.editBuffer + UInt32(Patch.Offset.param(module, 0)), 12)
    }

    public func setChain(_ chain: [Int]) throws {
        guard chain.count == 6, Set(chain) == Set(0..<6) else { return }
        try write(.dev, Address.editBuffer + UInt32(Patch.Offset.chain), chain.map { UInt8($0) })
    }

    public func setVolume(_ value: Int) throws {
        try write(.dev, Address.editBuffer + UInt32(Patch.Offset.volume), Patch.word(value))
    }

    /// Load a whole patch into the edit buffer (audition; not stored).
    public func loadIntoEditBuffer(_ patch: Patch) throws {
        try write(.dev, Address.editBuffer, patch.bytes)
    }

    // MARK: globals

    public func selectSlot(_ slot: Int) throws {
        guard (0..<Bank.slots).contains(slot) else { return }
        try write(.dev, Address.selectSlot + UInt32(slot), [0x01])
    }

    public func setBypass(_ on: Bool) throws {
        try write(.dev, Address.bypass, [on ? 1 : 0])
    }

    public func setLoopback(_ on: Bool) throws {
        try write(.dev, Address.loopback, [on ? 1 : 0])
    }

    // MARK: saving (writes the pedal's flash)

    /// Store `patch` in `slot` permanently, then make that slot active. Same sequence as the official app.
    public func save(_ patch: Patch, to slot: Int) throws {
        guard (0..<Bank.slots).contains(slot) else { return }
        let addr = Address.presetTable + UInt32(slot * Patch.size)
        try write(.dev, addr, patch.bytes)
        let back = try read(.dev, addr, Patch.size)
        guard back == patch.bytes else { throw LinkError.unexpectedReply("read-back differs; nothing was committed") }
        try write(.dev, Address.commit, [])
        Thread.sleep(forTimeInterval: 0.1)
        try selectSlot(slot)
        Thread.sleep(forTimeInterval: 0.1)
    }

    // MARK: tuner

    public func setTuner(_ on: Bool) throws {
        try write(.dev, Address.tuner + 2, [on ? 1 : 0])
    }

    public func tuner() throws -> TunerReading {
        let t = try read(.dev, Address.tuner, 6)
        let ref = Int(t[1] & 0x7f) - Int(t[1] & 0x80) + 440
        let note: Int? = (1...12).contains(Int(t[4])) ? Int(t[4]) - 1 : nil
        return TunerReading(bypassVolume: Int(t[0]), referenceHz: ref, running: t[3] == 1,
                            note: note, silent: t[4] == 0xff, deviation: Int(t[5]))
    }

    public func setTunerReference(_ hz: Int) throws {
        let v = min(max(hz, 430), 450) - 440
        try write(.dev, Address.tuner + 1, [UInt8(bitPattern: Int8(v))])
    }

    public func setTunerBypassVolume(_ v: Int) throws {
        try write(.dev, Address.tuner, [UInt8(min(max(v, 0), 100))])
    }
}
