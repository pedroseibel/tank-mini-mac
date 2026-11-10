import CoreAudio
import Foundation

/// How macOS sees the pedal's audio, and the fix for using it as one interface.
///
/// The pedal's firmware declares its recording and playback sides as two separate USB
/// audio functions, so macOS lists two devices, both called "USB-Audio": one with only
/// inputs, one with only outputs. Apps that want a single device for both directions
/// cannot use that. The fix needs no driver: a combined ("aggregate") device that joins
/// the two, which is what `createCombinedDevice` sets up.
@MainActor
final class AudioSetup: ObservableObject {
    static let combinedUID = "TankMini.CombinedDevice"
    static let combinedName = "Tank Mini"

    struct Side: Equatable {
        var id: AudioObjectID
        var uid: String
        var sampleRate: Double
        var channels: Int
    }

    @Published var input: Side?
    @Published var output: Side?
    @Published var combinedExists = false
    @Published var error: String?

    let isDemo: Bool
    private var timer: Timer?

    init(demo: Bool) {
        isDemo = demo
        if demo {
            input = Side(id: 1, uid: "in", sampleRate: 44100, channels: 2)
            output = Side(id: 2, uid: "out", sampleRate: 44100, channels: 2)
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var bothPresent: Bool { input != nil && output != nil }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func allDevices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func sampleRate(_ device: AudioObjectID) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &rate)
        return rate
    }

    // MARK: state

    func refresh() {
        guard !isDemo else { return }
        var foundIn: Side?
        var foundOut: Side?
        var foundCombined = false
        for device in AudioSetup.allDevices() {
            let uid = AudioSetup.string(device, kAudioDevicePropertyDeviceUID)
            if uid == AudioSetup.combinedUID { foundCombined = true; continue }
            guard AudioSetup.string(device, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") else { continue }
            let ins = AudioSetup.channels(device, kAudioObjectPropertyScopeInput)
            let outs = AudioSetup.channels(device, kAudioObjectPropertyScopeOutput)
            let rate = AudioSetup.sampleRate(device)
            if ins > 0 { foundIn = Side(id: device, uid: uid, sampleRate: rate, channels: ins) }
            if outs > 0 { foundOut = Side(id: device, uid: uid, sampleRate: rate, channels: outs) }
        }
        if input != foundIn { input = foundIn }
        if output != foundOut { output = foundOut }
        if combinedExists != foundCombined { combinedExists = foundCombined }
    }

    // MARK: the fix

    /// Create one "Tank Mini" device that carries both the pedal's inputs and outputs.
    /// It appears in every app's audio device list and stays until removed.
    func createCombinedDevice() {
        guard !isDemo else { combinedExists = true; return }
        refresh()
        guard let input, let output else {
            error = String(localized: "The pedal’s audio is not connected.")
            return
        }
        guard !combinedExists else { return }
        // The output side is the clock; the input side is drift-corrected against it.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: AudioSetup.combinedName,
            kAudioAggregateDeviceUIDKey: AudioSetup.combinedUID,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0],
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var device = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        error = status == noErr ? nil : String(localized: "macOS could not create the combined device (error \(status)).")
        refresh()
    }

    func removeCombinedDevice() {
        guard !isDemo else { combinedExists = false; return }
        for device in AudioSetup.allDevices() where AudioSetup.string(device, kAudioDevicePropertyDeviceUID) == AudioSetup.combinedUID {
            let status = AudioHardwareDestroyAggregateDevice(device)
            error = status == noErr ? nil : String(localized: "macOS could not remove the combined device (error \(status)).")
        }
        refresh()
    }
}
