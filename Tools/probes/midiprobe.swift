// midiprobe: listen to the Tank Mini's MIDI port and optionally send raw messages.
// Usage: swift midiprobe.swift <listen-seconds> ["F0 7E 7F 06 01 F7" ...]
import CoreMIDI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(o, p, &s)
    return (s?.takeRetainedValue() as String?) ?? ""
}

func findEndpoint(count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
    for i in 0..<count {
        let e = get(i)
        var dev: MIDIDeviceRef = 0
        var ent: MIDIEntityRef = 0
        MIDIEndpointGetEntity(e, &ent)
        MIDIEntityGetDevice(ent, &dev)
        let maker = str(dev, kMIDIPropertyManufacturer) + str(e, kMIDIPropertyManufacturer)
        if maker.lowercased().contains("jieli") { return e }
    }
    return nil
}

let args = CommandLine.arguments.dropFirst()
let seconds = Double(args.first ?? "5") ?? 5
let toSend: [[UInt8]] = args.dropFirst().map { $0.split(separator: " ").compactMap { UInt8($0, radix: 16) } }

var client = MIDIClientRef()
MIDIClientCreate("tankprobe" as CFString, nil, nil, &client)

guard let src = findEndpoint(count: MIDIGetNumberOfSources(), get: MIDIGetSource),
      let dst = findEndpoint(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination) else {
    print("Tank Mini MIDI port not found"); exit(1)
}
print("source:", str(src, kMIDIPropertyDisplayName), "| destination:", str(dst, kMIDIPropertyDisplayName))

let start = Date()
var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { list, _ in
    var p = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let n = Int(p.length)
        let bytes = withUnsafeBytes(of: &p.data) { Array($0.prefix(n)) }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        print(String(format: "%7.3f  IN  %@", Date().timeIntervalSince(start), hex))
        p = MIDIPacketNext(&p).pointee
    }
}
MIDIPortConnectSource(inPort, src, nil)

var outPort = MIDIPortRef()
MIDIOutputPortCreate(client, "out" as CFString, &outPort)

func send(_ bytes: [UInt8]) {
    let size = MemoryLayout<MIDIPacketList>.size + bytes.count
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
    defer { buf.deallocate() }
    let list = buf.assumingMemoryBound(to: MIDIPacketList.self)
    var pkt = MIDIPacketListInit(list)
    pkt = MIDIPacketListAdd(list, size, pkt, 0, bytes.count, bytes)
    MIDISend(outPort, dst, list)
    print(String(format: "%7.3f  OUT %@", Date().timeIntervalSince(start), bytes.map { String(format: "%02X", $0) }.joined(separator: " ")))
}

var delay = 0.5
for msg in toSend where !msg.isEmpty {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { send(msg) }
    delay += 0.6
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("done"); exit(0) }
RunLoop.main.run()
