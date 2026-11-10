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
    /// Semitones above A: 0 = A, 1 = A♯ ... 7 = E ... 11 = G♯. Nil when there is no note.
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

    public static let noteNames = ["A", "A♯", "B", "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯"]

    /// Turn the pedal's note byte into semitones above A.
    ///
    /// The numbering depends on the firmware:
    ///   - 008 (measured on a real unit): 0 = A, 1 = A♯ ... 11 = G♯. An open A string
    ///     reads 0 and the low E string reads 7.
    ///   - 004 (from the community notes): 1 = G♯, 2 = A ... 12 = G, and 0 means
    ///     "signal but no stable note".
    /// 0xFF is silence on both. Versions between the two are assumed to behave like 008.
    public static func noteIndex(raw: UInt8, firmwareVersion: Int) -> Int? {
        if firmwareVersion >= 5 {
            return raw <= 11 ? Int(raw) : nil
        }
        return (1...12).contains(raw) ? (Int(raw) + 10) % 12 : nil
    }
    public var noteName: String? { note.map { TunerReading.noteNames[$0] } }
    public var inTune: Bool { note != nil && (118...136).contains(deviation) }

    /// Deviation in cents. The raw byte runs 0...254 around a centre of 127 and the official
    /// app draws it on a scale of -50...+50 cents, so one step is about 0.4 cent.
    public var cents: Double { Double(deviation - 127) * 50.0 / 127.0 }
}

/// Steadies the pedal's raw tuner readings so they can be read while tuning.
///
/// The pedal reports a note and a deviation many times a second, and the raw stream
/// flickers: the note drops out between plucks or jumps to a neighbour for one reading,
/// and the deviation jitters. This filter
///   - changes the shown note only after the new note is seen several times in a row,
///   - keeps the last note briefly when the signal drops out,
///   - takes the median of recent deviations, then eases toward it,
///   - switches "in tune" on inside a narrow window and off outside a wider one.
public struct TunerFilter {
    public private(set) var note: Int?
    public private(set) var cents: Double = 0
    public private(set) var inTune = false

    private var candidate: Int?
    private var candidateCount = 0
    private var recent: [Double] = []
    private var lastHeard = Date.distantPast

    public init() {}

    public mutating func add(_ reading: TunerReading, at now: Date = Date()) {
        guard let heard = reading.note else {
            candidate = nil
            candidateCount = 0
            if now.timeIntervalSince(lastHeard) > 0.7 { reset() }
            return
        }
        lastHeard = now
        if heard == note {
            candidate = nil
            candidateCount = 0
            recent.append(reading.cents)
            if recent.count > 7 { recent.removeFirst() }
            let target = recent.sorted()[recent.count / 2]
            cents += (target - cents) * 0.35
        } else {
            if heard == candidate { candidateCount += 1 } else { candidate = heard; candidateCount = 1 }
            // A first note appears quickly; replacing a note already shown takes longer.
            if candidateCount >= (note == nil ? 2 : 4) {
                note = heard
                recent = [reading.cents]
                cents = reading.cents
                candidate = nil
                candidateCount = 0
                inTune = false
            }
        }
        if note != nil {
            if abs(cents) <= 3 { inTune = true } else if abs(cents) > 5 { inTune = false }
        }
    }

    public mutating func reset() {
        note = nil
        cents = 0
        inTune = false
        recent = []
        candidate = nil
        candidateCount = 0
    }

    public var noteName: String? { note.map { TunerReading.noteNames[$0] } }
}

/// High-level commands. All calls block until the pedal answers; call them off the main thread.
public final class Pedal {
    public let link: MIDILink

    /// Firmware name reported during the opening handshake, e.g. "TANK MINI_004".
    public private(set) var firmware = ""

    /// The number at the end of the firmware name ("TANK MINI_008" -> 8); 0 if there is none.
    public var firmwareVersion: Int {
        Int(firmware.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
    }

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
        let reply = try link.transact(Frame(cmd: Command.identity), timeout: timeout) { $0.cmd == Command.identity }
        guard reply.cmd == Command.identity else { throw LinkError.unexpectedReply(reply.bytes.hex) }
        let name = reply.body.prefix { $0 != 0 }
        return String(decoding: name, as: UTF8.self)
    }

    private func header(_ region: Region, _ addr: UInt32, _ len: Int) -> [UInt8] {
        [region.rawValue,
         UInt8(addr & 0xff), UInt8((addr >> 8) & 0xff), UInt8((addr >> 16) & 0xff), UInt8((addr >> 24) & 0xff),
         UInt8(len & 0xff), UInt8((len >> 8) & 0xff), UInt8((len >> 16) & 0xff)]
    }

    /// One request, sent again (up to three more times) if the pedal stays silent. Reads and writes here are
    /// idempotent, and a request can be lost when another program uses the port at the same moment.
    private func exchange(_ frame: Frame, matching: (Frame) -> Bool) throws -> Frame {
        var lastError: Error = LinkError.timeout
        for attempt in 0..<4 {
            do {
                return try link.transact(frame, timeout: attempt == 0 ? 0.25 : 0.5, matching: matching)
            } catch LinkError.timeout {
                lastError = LinkError.timeout
                // Back off by an uneven amount so two programs do not collide again in step.
                Thread.sleep(forTimeInterval: Double.random(in: 0.02...0.08))
            }
        }
        throw lastError
    }

    public func read(_ region: Region, _ addr: UInt32, _ len: Int) throws -> [UInt8] {
        let head = header(region, addr, len)
        let reply = try exchange(Frame(cmd: Command.read, body: head)) { reply in
            // Our data (the pedal echoes the request header), or a refusal.
            (reply.cmd == Command.read && Array(reply.body.prefix(head.count)) == head)
                || (reply.cmd == Command.ack && reply.body.first != 0)
        }
        if reply.cmd == Command.ack { throw LinkError.rejected(reply.body.first ?? 0xff) }
        guard reply.cmd == Command.read, reply.body.count == head.count + len, Array(reply.body.prefix(head.count)) == head else {
            throw LinkError.unexpectedReply(reply.bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        return Array(reply.body.dropFirst(head.count))
    }

    public func write(_ region: Region, _ addr: UInt32, _ data: [UInt8]) throws {
        let reply = try exchange(Frame(cmd: Command.write, body: header(region, addr, data.count) + data)) { $0.cmd == Command.ack }
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
        let note = TunerReading.noteIndex(raw: t[4], firmwareVersion: firmwareVersion)
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
