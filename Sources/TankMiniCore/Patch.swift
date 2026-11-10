import Foundation

/// One preset: 92 bytes, exactly as the pedal stores it.
///
///   0x00  u16   preset volume 0...100
///   0x02  6     signal chain: module ids in playing order
///   0x08  6     on/off per module id
///   0x0E  6     model ("unit") per module id
///   0x14  36    parameters, i16 LE, [module][6]
public struct Patch: Equatable {
    public static let size = 92
    public static let moduleCount = 6
    public static let paramsPerModule = 6

    public enum Offset {
        public static let volume = 0x00
        public static let chain = 0x02
        public static let enabled = 0x08
        public static let unit = 0x0E
        public static let params = 0x14
        public static func param(_ module: Int, _ index: Int) -> Int { params + module * 12 + index * 2 }
    }

    public var bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Patch.size else { return nil }
        self.bytes = bytes
    }

    public var volume: Int {
        get { Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)) }
        set { setWord(Offset.volume, newValue) }
    }

    /// Module ids in signal order. Falls back to 0...5 if the stored bytes are not a permutation.
    public var chain: [Int] {
        get {
            let c = bytes[Offset.chain..<(Offset.chain + 6)].map(Int.init)
            return Set(c) == Set(0..<6) ? c : Array(0..<6)
        }
        set {
            guard Set(newValue) == Set(0..<6), newValue.count == 6 else { return }
            for (i, m) in newValue.enumerated() { bytes[Offset.chain + i] = UInt8(m) }
        }
    }

    public func isOn(_ module: Int) -> Bool { bytes[Offset.enabled + module] != 0 }
    public mutating func setOn(_ module: Int, _ on: Bool) { bytes[Offset.enabled + module] = on ? 1 : 0 }

    public func unit(_ module: Int) -> Int { Int(bytes[Offset.unit + module]) }
    public mutating func setUnit(_ module: Int, _ unit: Int) { bytes[Offset.unit + module] = UInt8(clamping: unit) }

    public func param(_ module: Int, _ index: Int) -> Int {
        let o = Offset.param(module, index)
        return Int(Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8))
    }

    public mutating func setParam(_ module: Int, _ index: Int, _ value: Int) {
        setWord(Offset.param(module, index), value)
    }

    public mutating func setParams(_ module: Int, raw: [UInt8]) {
        guard raw.count == 12 else { return }
        bytes.replaceSubrange(Offset.param(module, 0)..<Offset.param(module, 0) + 12, with: raw)
    }

    private mutating func setWord(_ offset: Int, _ value: Int) {
        let w = UInt16(bitPattern: Int16(clamping: value))
        bytes[offset] = UInt8(w & 0xff)
        bytes[offset + 1] = UInt8(w >> 8)
    }

    public static func word(_ value: Int) -> [UInt8] {
        let w = UInt16(bitPattern: Int16(clamping: value))
        return [UInt8(w & 0xff), UInt8(w >> 8)]
    }
}

/// The whole preset library: 21 patches followed by "PATCHEND\0\0" (1942 bytes),
/// the same layout the official app uses for its .atkm files.
public enum Bank {
    public static let slots = 21
    public static let trailer: [UInt8] = Array("PATCHEND".utf8) + [0, 0]
    public static let size = slots * Patch.size + trailer.count

    /// "1A" ... "7C"
    public static func slotName(_ slot: Int) -> String {
        "\(slot / 3 + 1)\(["A", "B", "C"][slot % 3])"
    }
}
