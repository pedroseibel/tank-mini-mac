// audioprobe: dump how CoreAudio sees every audio device (focus: the Tank Mini).
import CoreAudio
import Foundation

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
    var a = a
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<T>.stride
    let buf = UnsafeMutablePointer<T>.allocate(capacity: n)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buf, count: n))
}

func getValue<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var a = a
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel)
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}

func fourcc(_ v: UInt32) -> String {
    let b = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    let flags = f.mFormatFlags
    let kind = (flags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int"
    return "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit \(kind), \(fourcc(f.mFormatID))"
}

let devices = getArray(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
let onlyUSB = CommandLine.arguments.contains("--usb")

for d in devices {
    let transport = getValue(d, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    if onlyUSB && transport != kAudioDeviceTransportTypeUSB { continue }
    print("== \(getString(d, kAudioObjectPropertyName))  [id \(d)]")
    print("   maker: \(getString(d, kAudioObjectPropertyManufacturer)) | uid: \(getString(d, kAudioDevicePropertyDeviceUID)) | transport: \(fourcc(transport))")
    print("   alive: \(getValue(d, addr(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 9) | running somewhere: \(getValue(d, addr(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 9) | hogged by pid: \(getValue(d, addr(kAudioDevicePropertyHogMode), pid_t(-1)) ?? -2)")
    print("   nominal rate: \(getValue(d, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0) | buffer frames: \(getValue(d, addr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0)")
    let rates = getArray(d, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self)
    print("   available rates: \(rates.map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))-\(Int($0.mMaximum))" }.joined(separator: ", "))")
    print("   clock domain: \(getValue(d, addr(kAudioDevicePropertyClockDomain), UInt32(0)) ?? 0)")
    for (label, scope) in [("input", kAudioObjectPropertyScopeInput), ("output", kAudioObjectPropertyScopeOutput)] {
        let streams = getArray(d, addr(kAudioDevicePropertyStreams, scope), AudioStreamID.self)
        if streams.isEmpty { continue }
        let latency = getValue(d, addr(kAudioDevicePropertyLatency, scope), UInt32(0)) ?? 0
        let safety = getValue(d, addr(kAudioDevicePropertySafetyOffset, scope), UInt32(0)) ?? 0
        print("   \(label): \(streams.count) stream(s), latency \(latency) fr, safety offset \(safety) fr")
        for s in streams {
            if let phys = getValue(s, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) {
                print("     physical now: \(describe(phys))")
            }
            if let virt = getValue(s, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()) {
                print("     virtual now:  \(describe(virt))")
            }
            let avail = getArray(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self)
            let set = Set(avail.map { describe($0.mFormat) })
            print("     physical formats offered: \(set.sorted().joined(separator: " | "))")
        }
        // volume / mute controls
        var hasVol = addr(kAudioDevicePropertyVolumeScalar, scope)
        print("     master volume control: \(AudioObjectHasProperty(d, &hasVol))")
    }
}
let defIn = getValue(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0)) ?? 0
let defOut = getValue(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
print("default input id: \(defIn) | default output id: \(defOut)")
