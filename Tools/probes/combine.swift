// combine: create (or with "remove", delete) the public "Tank Mini" combined audio device.
// Uses the same name and UID as the app's Create Combined Device button, so the app recognises it.
import CoreAudio
import Foundation

let combinedUID = "TankMini.CombinedDevice"

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

let existing = devices().first { getString($0, kAudioDevicePropertyDeviceUID) == combinedUID }

if CommandLine.arguments.contains("remove") {
    guard let existing else { print("no combined device to remove"); exit(0) }
    let err = AudioHardwareDestroyAggregateDevice(existing)
    print(err == noErr ? "removed" : "remove failed: \(err)")
    exit(err == noErr ? 0 : 1)
}

if existing != nil { print("combined device already exists"); exit(0) }

var inUID = "", outUID = ""
for d in devices() where getString(d, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") {
    if streams(d, kAudioObjectPropertyScopeInput) > 0 { inUID = getString(d, kAudioDevicePropertyDeviceUID) }
    if streams(d, kAudioObjectPropertyScopeOutput) > 0 { outUID = getString(d, kAudioDevicePropertyDeviceUID) }
}
guard !inUID.isEmpty, !outUID.isEmpty else { print("pedal audio not found"); exit(1) }

let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tank Mini",
    kAudioAggregateDeviceUIDKey: combinedUID,
    kAudioAggregateDeviceIsPrivateKey: 0,
    kAudioAggregateDeviceIsStackedKey: 0,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outUID, kAudioSubDeviceDriftCompensationKey: 0],
        [kAudioSubDeviceUIDKey: inUID, kAudioSubDeviceDriftCompensationKey: 1],
    ],
]
var device = AudioObjectID(0)
let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
print(err == noErr ? "created \"Tank Mini\" (id \(device))" : "create failed: \(err)")
exit(err == noErr ? 0 : 1)
