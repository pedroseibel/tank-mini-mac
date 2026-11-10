import CoreMIDI
import Foundation

public enum LinkError: Error, LocalizedError {
    case notFound
    case sendFailed(OSStatus)
    case timeout
    case rejected(UInt8)
    case unexpectedReply(String)

    public var errorDescription: String? {
        switch self {
        // Looked up in the app bundle's Localizable.strings; English is the fallback.
        case .notFound: return NSLocalizedString("Tank Mini not found on USB", comment: "")
        case .sendFailed(let s): return String(format: NSLocalizedString("MIDI send failed (%d)", comment: ""), Int(s))
        case .timeout: return NSLocalizedString("The pedal did not answer", comment: "")
        case .rejected(let s): return String(format: NSLocalizedString("The pedal rejected the command (status %d)", comment: ""), Int(s))
        case .unexpectedReply(let s): return String(format: NSLocalizedString("Unexpected reply: %@", comment: ""), s)
        }
    }
}

/// Request / reply link to the pedal's USB-MIDI port through CoreMIDI.
/// The pedal never talks unprompted, so every exchange is one frame out, one frame in.
public final class MIDILink {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    private let rx = NSCondition()
    private var partial: [UInt8] = []
    private var inSysex = false
    private var inbox: [Frame] = []
    private let txLock = NSLock()

    /// Called with every raw frame sent / received, for the traffic log.
    public var trace: ((_ outgoing: Bool, _ frame: Frame) -> Void)?

    public init() throws {
        var status = MIDIClientCreateWithBlock("TankMini" as CFString, &client) { _ in }
        guard status == noErr else { throw LinkError.sendFailed(status) }

        guard let (src, dst) = MIDILink.findEndpoints() else {
            MIDIClientDispose(client)
            throw LinkError.notFound
        }
        source = src
        destination = dst

        status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { MIDIClientDispose(client); throw LinkError.sendFailed(status) }
        status = MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        guard status == noErr else { MIDIClientDispose(client); throw LinkError.sendFailed(status) }
        status = MIDIPortConnectSource(inPort, source, nil)
        guard status == noErr else { MIDIClientDispose(client); throw LinkError.sendFailed(status) }
    }

    deinit {
        MIDIClientDispose(client)
    }

    /// True while the pedal's port is still present in the system.
    public var isAlive: Bool {
        MIDILink.findEndpoints().map { $0.0 == source && $0.1 == destination } ?? false
    }

    // MARK: endpoint discovery

    private static func string(_ obj: MIDIObjectRef, _ prop: CFString) -> String {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, prop, &s) == noErr, let s else { return "" }
        return s.takeRetainedValue() as String
    }

    private static func isTank(_ endpoint: MIDIEndpointRef) -> Bool {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        MIDIEntityGetDevice(entity, &device)
        let text = [string(device, kMIDIPropertyManufacturer), string(endpoint, kMIDIPropertyManufacturer),
                    string(device, kMIDIPropertyName), string(endpoint, kMIDIPropertyDisplayName)]
            .joined(separator: " ").lowercased()
        return text.contains("jieli") || text.contains("tank")
    }

    private static func findEndpoints() -> (MIDIEndpointRef, MIDIEndpointRef)? {
        var src: MIDIEndpointRef?
        var dst: MIDIEndpointRef?
        for i in 0..<MIDIGetNumberOfSources() where isTank(MIDIGetSource(i)) { src = MIDIGetSource(i); break }
        for i in 0..<MIDIGetNumberOfDestinations() where isTank(MIDIGetDestination(i)) { dst = MIDIGetDestination(i); break }
        guard let src, let dst else { return nil }
        return (src, dst)
    }

    // MARK: receive

    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
        var complete: [Frame] = []
        for _ in 0..<list.pointee.numPackets {
            let length = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            for i in 0..<length {
                let b = data[i]
                if b >= 0xF8 { continue } // realtime bytes may interleave
                if b == 0xF0 {
                    partial = [b]
                    inSysex = true
                } else if inSysex {
                    partial.append(b)
                    if b == 0xF7 {
                        if let frame = Frame.parse(sysex: partial) { complete.append(frame) }
                        partial = []
                        inSysex = false
                    } else if b & 0x80 != 0 {
                        partial = []
                        inSysex = false
                    }
                }
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        guard !complete.isEmpty else { return }
        rx.lock()
        inbox.append(contentsOf: complete)
        rx.broadcast()
        rx.unlock()
        for frame in complete { trace?(false, frame) }
    }

    // MARK: send

    private func send(_ bytes: [UInt8]) throws {
        let size = MemoryLayout<MIDIPacketList>.size + bytes.count + 64
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIPacketList.self)
        let packet = MIDIPacketListInit(list)
        _ = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
        let status = MIDISend(outPort, destination, list)
        guard status == noErr else { throw LinkError.sendFailed(status) }
    }

    /// Send one frame and wait for the pedal's reply. Safe to call from any thread
    /// except the CoreMIDI callback; calls are serialised.
    ///
    /// The MIDI port is shared: if another program is talking to the pedal, its replies
    /// arrive here too. `matching` says which reply belongs to this request; anything
    /// else is skipped.
    public func transact(_ frame: Frame, timeout: TimeInterval = 1.0, matching: (Frame) -> Bool = { _ in true }) throws -> Frame {
        txLock.lock()
        defer { txLock.unlock() }

        rx.lock()
        inbox.removeAll()
        rx.unlock()

        trace?(true, frame)
        try send(frame.sysex)

        let deadline = Date().addingTimeInterval(timeout)
        rx.lock()
        defer { rx.unlock() }
        while true {
            while let reply = inbox.first {
                inbox.removeFirst()
                if matching(reply) { return reply }
            }
            if !rx.wait(until: deadline) { throw LinkError.timeout }
        }
    }
}
