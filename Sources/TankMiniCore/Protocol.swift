import Foundation

// Wire protocol of the M-VAVE Tank Mini over USB-MIDI.
//
// Every message is a SysEx with no manufacturer ID:  F0 <pack7(frame)> F7
// Frame:  00 59 | cmd | len (u24 LE) | body | checksum      checksum = ~sum(body)
//
// Protocol facts come from the community reverse-engineering notes in
// github.com/viniciusapl97/tankmini-linux (docs/protocol), re-verified on this unit.

/// 8-bit to 7-bit packing: the payload is one LSB-first bit stream, 7 bits per MIDI byte.
public enum Sys7 {
    public static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 7 + 1)
        var accum: UInt32 = 0
        var nbits: UInt32 = 0
        for b in data {
            accum |= UInt32(b) << nbits
            nbits += 8
            while nbits >= 7 {
                out.append(UInt8(accum & 0x7f))
                accum >>= 7
                nbits -= 7
            }
        }
        out.append(UInt8(accum & 0x7f)) // the flush byte is always sent
        return out
    }

    public static func decode(_ data: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 7 / 8)
        var accum: UInt32 = 0
        var nbits: UInt32 = 0
        for b in data {
            if b & 0x80 != 0 { return nil }
            accum |= UInt32(b) << nbits
            nbits += 7
            while nbits >= 8 {
                out.append(UInt8(accum & 0xff))
                accum >>= 8
                nbits -= 8
            }
        }
        return out
    }
}

/// Commands this app sends. ERASE (0x21) exists in the protocol and is deliberately absent.
public enum Command {
    public static let ack: UInt8 = 0x00
    public static let identity: UInt8 = 0x11
    public static let write: UInt8 = 0x22
    public static let read: UInt8 = 0x23
}

public struct Frame: Equatable {
    public var cmd: UInt8
    public var body: [UInt8]

    public init(cmd: UInt8, body: [UInt8] = []) {
        self.cmd = cmd
        self.body = body
    }

    public static func checksum(_ body: [UInt8]) -> UInt8 {
        ~body.reduce(UInt8(0)) { $0 &+ $1 }
    }

    /// Raw frame, before packing.
    public var bytes: [UInt8] {
        let n = body.count
        return [0x00, 0x59, cmd, UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff)]
            + body + [Frame.checksum(body)]
    }

    /// Complete MIDI message: F0 ... F7.
    public var sysex: [UInt8] {
        [0xF0] + Sys7.encode(bytes) + [0xF7]
    }

    /// Parse a complete SysEx message (including F0 / F7). Returns nil for anything
    /// that is not a well-formed frame with a matching checksum.
    public static func parse(sysex: [UInt8]) -> Frame? {
        guard sysex.count >= 3, sysex.first == 0xF0, sysex.last == 0xF7,
              let raw = Sys7.decode(Array(sysex[1..<(sysex.count - 1)])),
              raw.count >= 7, raw[0] == 0x00, raw[1] == 0x59 else { return nil }
        let len = Int(raw[3]) | Int(raw[4]) << 8 | Int(raw[5]) << 16
        guard raw.count >= 7 + len else { return nil }
        let body = Array(raw[6..<(6 + len)])
        guard raw[6 + len] == checksum(body) else { return nil }
        return Frame(cmd: raw[2], body: body)
    }
}

/// Memory regions the pedal serves.
public enum Region: UInt8 {
    case dev = 4 // presets, live edit buffer, globals, tuner
    case usr = 5 // amp / cab model names and slots
}

/// Addresses used by this app. Anything that erases or factory-resets is left out on purpose.
public enum Address {
    public static let presetTable: UInt32 = 0x0000_0000 // + slot * 92
    public static let editBuffer: UInt32 = 0x1000_0000 // the patch that is playing
    public static let glob: UInt32 = 0x2000_0000 // [active slot, ?, bypass, ?]
    public static let bypass: UInt32 = 0x2000_0002
    public static let tuner: UInt32 = 0x7010_0000
    public static let loopback: UInt32 = 0xD000_0000
    public static let selectSlot: UInt32 = 0xE000_0000 // + slot
    public static let commit: UInt32 = 0xF000_0000 // empty write: store the table in flash
    public static let cabNames: UInt32 = 0x8000_0000 // region usr, 20 x 14
    public static let ampNames: UInt32 = 0x9000_0000 // region usr, 20 x 14
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
