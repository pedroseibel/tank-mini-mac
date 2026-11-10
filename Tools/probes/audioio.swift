// audioio: start each Jieli USB audio device for a few seconds and report whether
// the stream really runs. Output is fed digital silence, so nothing is audible.
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
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}

final class Stats {
    var callbacks = 0
    var inFrames = 0, outFrames = 0
    var peak: Float = 0
    var nonZero = 0
    var firstSample: Float64 = -1, lastSample: Float64 = 0
    var firstHost: UInt64 = 0, lastHost: UInt64 = 0
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "3") ?? 3
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)

for d in devices() where getString(d, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") {
    let uid = getString(d, kAudioDevicePropertyDeviceUID)
    let stats = Stats()
    var procID: AudioDeviceIOProcID?
    let err = AudioDeviceCreateIOProcIDWithBlock(&procID, d, nil) { now, input, inputTime, output, outputTime in
        stats.callbacks += 1
        let t = inputTime.pointee.mSampleTime != 0 ? inputTime.pointee : outputTime.pointee
        if stats.firstSample < 0 { stats.firstSample = t.mSampleTime; stats.firstHost = t.mHostTime }
        stats.lastSample = t.mSampleTime; stats.lastHost = t.mHostTime
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for buf in inList {
            guard let p = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            let samples = p.bindMemory(to: Float32.self, capacity: n)
            stats.inFrames += n / max(1, Int(buf.mNumberChannels))
            for i in 0..<n { let v = abs(samples[i]); if v > 0 { stats.nonZero += 1 }; if v > stats.peak { stats.peak = v } }
        }
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buf in outList {
            guard let p = buf.mData else { continue }
            memset(p, 0, Int(buf.mDataByteSize))
            stats.outFrames += Int(buf.mDataByteSize) / MemoryLayout<Float32>.size / max(1, Int(buf.mNumberChannels))
        }
    }
    guard err == noErr, let procID else { print("\(uid): cannot create IOProc (\(err))"); continue }
    let t0 = Date()
    let startErr = AudioDeviceStart(d, procID)
    let startMs = Date().timeIntervalSince(t0) * 1000
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(d, procID)
    AudioDeviceDestroyIOProcID(d, procID)

    let hostSeconds = Double(stats.lastHost - stats.firstHost) * Double(tb.numer) / Double(tb.denom) / 1e9
    let rate = hostSeconds > 0 ? (stats.lastSample - stats.firstSample) / hostSeconds : 0
    print("== \(uid.split(separator: ":").last ?? "") (\(stats.inFrames > 0 ? "input" : "output"))")
    print("   start: \(startErr == noErr ? "ok" : "ERROR \(startErr)") in \(String(format: "%.0f", startMs)) ms | callbacks: \(stats.callbacks) (expected ~\(Int(seconds * 44100 / 512)))")
    print("   frames in: \(stats.inFrames) | frames out: \(stats.outFrames) | measured rate: \(String(format: "%.1f", rate)) Hz")
    if stats.inFrames > 0 {
        let db = stats.peak > 0 ? 20 * log10(stats.peak) : -Float.infinity
        print("   input peak: \(String(format: "%.5f", stats.peak)) (\(String(format: "%.1f", db)) dBFS) | non-zero samples: \(stats.nonZero)")
    }
}
