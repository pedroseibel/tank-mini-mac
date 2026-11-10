import Foundation

/// The six effect modules. The raw value is the module id used on the wire.
public enum Module: Int, CaseIterable, Identifiable {
    case fx = 0, amp, mod, delay, reverb, cab

    public var id: Int { rawValue }

    public var code: String {
        switch self {
        case .fx: return "FX"
        case .amp: return "AMP"
        case .mod: return "MOD"
        case .delay: return "DLY"
        case .reverb: return "REV"
        case .cab: return "CAB"
        }
    }

    public var title: String {
        switch self {
        case .fx: return "Dynamics"
        case .amp: return "Amp"
        case .mod: return "Modulation"
        case .delay: return "Delay"
        case .reverb: return "Reverb"
        case .cab: return "Cabinet"
        }
    }

    /// Amp and cab models are named by the pedal itself (20 slots each).
    public var usesDeviceNames: Bool { self == .amp || self == .cab }
}

public struct Variant {
    public let name: String
    public let params: [String]
}

/// Model lists and parameter names, in wire order (taken from the official app's tables).
public enum Catalog {
    static let fx = [
        Variant(name: "Noise Gate", params: ["Gate"]),
        Variant(name: "Boost", params: ["Gate", "Gain"]),
        Variant(name: "Compressor", params: ["Gate", "Sustain", "Attack", "Level"]),
    ]
    static let mod = [
        Variant(name: "Chorus", params: ["Speed", "Depth", "Mix"]),
        Variant(name: "Phaser", params: ["Speed", "Param A", "Param B", "Feedback"]),
        Variant(name: "Tremolo", params: ["Speed", "Depth", "Level"]),
        Variant(name: "Flanger", params: ["Speed", "Depth", "Feedback", "Mix"]),
        Variant(name: "Vibrato", params: ["Speed", "Depth"]),
        Variant(name: "Univibe", params: ["Speed", "Depth", "Mix"]),
        Variant(name: "Autofilter", params: ["Speed", "Min", "Max", "Mix", "Feedback"]),
    ]
    static let delay = [
        Variant(name: "Analog", params: ["Time", "Feedback", "Mix", "Phaser", "Pitch"]),
        Variant(name: "Duck", params: ["Time", "Feedback", "Mix", "Unpack", "Speed", "Depth"]),
        Variant(name: "Tape", params: ["Time", "Feedback", "Mix", "Grit", "Speed", "Depth"]),
        Variant(name: "Dual", params: ["Time", "Feedback", "Mix", "T-Mode", "Speed", "Depth"]),
        Variant(name: "Lo-fi", params: ["Time", "Feedback", "Mix", "Grit", "Speed", "Depth"]),
    ]
    static let reverb = [
        Variant(name: "Room", params: ["Decay", "Mix", "High Pass", "Low Pass", "Depth"]),
        Variant(name: "Hall", params: ["Decay", "Mix", "High Pass", "Low Pass", "Depth"]),
        Variant(name: "Swell", params: ["Decay", "Mix", "High Pass", "Low Pass", "Rise"]),
        Variant(name: "Spring", params: ["Decay", "Mix", "High Pass", "Low Pass", "Combs"]),
        Variant(name: "Shimmer", params: ["Decay", "Mix", "Tone", "Pitch", "Amount"]),
        Variant(name: "Cloud", params: ["Decay", "Mix", "High Pass", "Low Pass", "Diffusion"]),
    ]
    static let ampParams = ["Gain", "Level", "Bass", "Mid", "Treble"]
    static let cabParams = ["Level", "Low Cut", "High Cut"]

    static func variants(_ module: Module) -> [Variant] {
        switch module {
        case .fx: return fx
        case .mod: return mod
        case .delay: return delay
        case .reverb: return reverb
        case .amp, .cab: return []
        }
    }

    public static func modelCount(_ module: Module) -> Int {
        module.usesDeviceNames ? 20 : variants(module).count
    }

    /// Display name of model `unit` of a module. `deviceNames` are the amp / cab tables read from the pedal.
    public static func modelName(_ module: Module, unit: Int, deviceNames: [String] = []) -> String {
        if module.usesDeviceNames {
            if unit < deviceNames.count, !deviceNames[unit].isEmpty { return deviceNames[unit] }
            return "\(module.title) \(unit + 1)"
        }
        let list = variants(module)
        return unit < list.count ? list[unit].name : "\(module.title) \(unit + 1)"
    }

    /// Parameter names of a module for its current model, in wire order.
    public static func paramNames(_ module: Module, unit: Int) -> [String] {
        switch module {
        case .amp: return ampParams
        case .cab: return cabParams
        default:
            let list = variants(module)
            return unit < list.count ? list[unit].params : []
        }
    }

    /// Value in real units where the official app documents a scale; otherwise the raw 0...100.
    public static func formatted(_ name: String, module: Module, value: Int) -> String {
        guard module == .cab else { return "\(value)" }
        let v = Double(min(max(value, 0), 100))
        switch name {
        case "Low Cut": return String(format: "%.0f Hz", 20 + v * 280 / 100)
        case "High Cut": return String(format: "%.1f kHz", 5 + v * 13 / 100)
        default: return "\(value)"
        }
    }
}
