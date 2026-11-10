// tankctl: command-line access to the Tank Mini. Every command only READS from the pedal, except
// `check-write`, which writes the preset volume back with the value it already has.
import Foundation
import TankMiniCore

setvbuf(stdout, nil, _IOLBF, 0)

func selftest() -> Bool {
    var ok = true
    func check(_ name: String, _ cond: Bool) { print(cond ? "  ok   \(name)" : "  FAIL \(name)"); if !cond { ok = false } }
    // Vectors from the reference implementation / device captures.
    check("identity request bytes", Frame(cmd: Command.identity).sysex == [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0x00, 0xF7])
    check("pack example", Sys7.encode([0x12, 0x34, 0xAB, 0xCD]) == [0x12, 0x68, 0x2C, 0x6D, 0x0C])
    var roundTrip = true
    for n in 0..<200 {
        let data = (0..<n).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        guard let back = Sys7.decode(Sys7.encode(data)), Array(back.prefix(n)) == data else { roundTrip = false; break }
        let f = Frame(cmd: 0x22, body: data)
        if Frame.parse(sysex: f.sysex) != f { roundTrip = false; break }
    }
    check("pack / frame round trip", roundTrip)
    var p = Patch(bytes: [UInt8](repeating: 0, count: 92))!
    p.setParam(5, 5, 77); p.volume = 90; p.chain = [5, 4, 3, 2, 1, 0]
    check("patch accessors", p.param(5, 5) == 77 && p.bytes[90] == 77 && p.volume == 90 && p.chain == [5, 4, 3, 2, 1, 0])
    check("bank size", Bank.size == 1942 && Bank.slotName(20) == "7C" && Bank.slotName(0) == "1A")
    return ok
}

func describe(_ patch: Patch, amps: [String], cabs: [String]) {
    print("  volume \(patch.volume) | chain: \(patch.chain.map { Module(rawValue: $0)!.code }.joined(separator: " > "))")
    for module in Module.allCases {
        let unit = patch.unit(module.rawValue)
        let names = Catalog.paramNames(module, unit: unit)
        let model = Catalog.modelName(module, unit: unit, deviceNames: module == .amp ? amps : cabs)
        let params = names.enumerated().map { "\($1) \(Catalog.formatted($1, module: module, value: patch.param(module.rawValue, $0)))" }
        print("  \(module.code.padding(toLength: 3, withPad: " ", startingAt: 0)) \(patch.isOn(module.rawValue) ? "on " : "off") \(model.padding(toLength: 14, withPad: " ", startingAt: 0)) \(params.joined(separator: ", "))")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "state"

if command == "selftest" {
    exit(selftest() ? 0 : 1)
}

do {
    let pedal = try Pedal()
    if args.contains("--trace") {
        pedal.link.trace = { out, f in
            print("\(out ? ">>" : "<<") cmd \(String(format: "%02X", f.cmd)) len \(f.body.count)  \(f.body.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }
    switch command {
    case "id":
        print(try pedal.identity())
    case "state":
        let t0 = Date()
        print("identity: \(try pedal.identity())")
        let g = try pedal.globals()
        print("globals: \(g.raw.hex)  -> active preset \(Bank.slotName(g.activeSlot)), bypass \(g.bypassed ? "on" : "off")")
        let amps = try pedal.modelNames(.amp)
        let cabs = try pedal.modelNames(.cab)
        print("amp models: \(amps.joined(separator: ", "))")
        print("cab models: \(cabs.joined(separator: ", "))")
        let live = try pedal.editBuffer()
        print("playing now (edit buffer):")
        describe(live, amps: amps, cabs: cabs)
        let stored = try pedal.storedPatch(g.activeSlot)
        print("stored preset \(Bank.slotName(g.activeSlot)) \(stored == live ? "is identical to the edit buffer" : "DIFFERS from the edit buffer (unsaved edits)")")
        print(String(format: "done in %.0f ms", Date().timeIntervalSince(t0) * 1000))
    case "presets":
        let amps = try pedal.modelNames(.amp)
        let cabs = try pedal.modelNames(.cab)
        for slot in 0..<Bank.slots {
            print("preset \(Bank.slotName(slot))")
            describe(try pedal.storedPatch(slot), amps: amps, cabs: cabs)
        }
    case "backup":
        guard args.count > 1 else { print("usage: tankctl backup <file.atkm>"); exit(2) }
        let bank = try pedal.bank()
        try Data(bank).write(to: URL(fileURLWithPath: args[1]))
        print("wrote \(bank.count) bytes to \(args[1])")
    case "tuner":
        print(try pedal.tuner())
    case "check-write":
        // Confirms the write path and its acknowledgement without changing anything:
        // the playing patch's volume is written back unchanged, then compared.
        let before = try pedal.editBuffer()
        try pedal.setVolume(before.volume)
        let after = try pedal.editBuffer()
        print("wrote volume \(before.volume) back to the edit buffer: acknowledged, patch \(after == before ? "unchanged" : "CHANGED")")
    default:
        print("usage: tankctl [selftest | id | state | presets | backup <file> | tuner | check-write] [--trace]")
        exit(2)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
