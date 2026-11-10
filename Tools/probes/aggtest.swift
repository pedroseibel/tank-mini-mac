// aggtest: build a PRIVATE combined device from the pedal's input and output (visible only to
// this process, gone when it exits), run it in both directions at once with silent output,
// and report whether the two sides stay in step.
import CoreAudio
import Foundation

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}
func streams(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size)
    return Int(size) / MemoryLayout<AudioStreamID>.size
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}

var inUID = "", outUID = ""
for d in devices() where getString(d, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") {
    if streams(d, kAudioObjectPropertyScopeInput) > 0 { inUID = getString(d, kAudioDevicePropertyDeviceUID) }
    if streams(d, kAudioObjectPropertyScopeOutput) > 0 { outUID = getString(d, kAudioDevicePropertyDeviceUID) }
}
guard !inUID.isEmpty, !outUID.isEmpty else { print("pedal audio not found"); exit(1) }

let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tank Mini (test)",
    kAudioAggregateDeviceUIDKey: "TankMini.PrivateTest.\(getpid())",
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceIsStackedKey: 0,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outUID, kAudioSubDeviceDriftCompensationKey: 0],
        [kAudioSubDeviceUIDKey: inUID, kAudioSubDeviceDriftCompensationKey: 1],
    ],
]
var agg = AudioObjectID(0)
let createErr = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
guard createErr == noErr else { print("create failed: \(createErr)"); exit(1) }
Thread.sleep(forTimeInterval: 0.5)
print("combined device: \(streams(agg, kAudioObjectPropertyScopeInput)) input stream(s), \(streams(agg, kAudioObjectPropertyScopeOutput)) output stream(s)")

var callbacks = 0, inFrames = 0, outFrames = 0, nonZero = 0
var peak: Float = 0
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, input, _, output, _ in
    callbacks += 1
    for buf in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
        guard let p = buf.mData else { continue }
        let n = Int(buf.mDataByteSize) / 4
        let s = p.bindMemory(to: Float32.self, capacity: n)
        inFrames += n / max(1, Int(buf.mNumberChannels))
        for i in 0..<n { let v = abs(s[i]); if v > 0 { nonZero += 1 }; if v > peak { peak = v } }
    }
    for buf in UnsafeMutableAudioBufferListPointer(output) {
        guard let p = buf.mData else { continue }
        memset(p, 0, Int(buf.mDataByteSize))
        outFrames += Int(buf.mDataByteSize) / 4 / max(1, Int(buf.mNumberChannels))
    }
}
let seconds = 4.0
let startErr = AudioDeviceStart(agg, procID)
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(agg, procID)
if let procID { AudioDeviceDestroyIOProcID(agg, procID) }
let destroyErr = AudioHardwareDestroyAggregateDevice(agg)

print("start: \(startErr == noErr ? "ok" : "ERROR \(startErr)") | callbacks: \(callbacks)")
print("frames in: \(inFrames) | frames out: \(outFrames) | expected about \(Int(seconds * 44100)) each")
print("input peak: \(String(format: "%.5f", peak)) | non-zero input samples: \(nonZero)")
print("removed test device: \(destroyErr == noErr ? "ok" : "ERROR \(destroyErr)")")
