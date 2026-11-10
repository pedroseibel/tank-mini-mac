// channels: listen to the pedal's USB recording input for a few seconds and report each
// channel's level separately, plus how alike the two channels are. Nothing is played.
// Usage: channels [seconds]
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

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
guard let device = devices().first(where: {
    getString($0, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") && streams($0, kAudioObjectPropertyScopeInput) > 0
}) else { print("pedal input not found"); exit(1) }

var sumL = 0.0, sumR = 0.0, sumLR = 0.0, sumDiff = 0.0
var peakL: Float = 0, peakR: Float = 0
var frames = 0

var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = list.first, let data = first.mData else { return }
    if first.mNumberChannels >= 2 { // interleaved
        let ch = Int(first.mNumberChannels)
        let n = Int(first.mDataByteSize) / 4 / ch
        let s = data.bindMemory(to: Float32.self, capacity: n * ch)
        for i in 0..<n {
            let l = s[i * ch], r = s[i * ch + 1]
            sumL += Double(l * l); sumR += Double(r * r); sumLR += Double(l * r); sumDiff += Double((l - r) * (l - r))
            peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
        }
        frames += n
    } else if list.count >= 2, let rData = list[1].mData { // one buffer per channel
        let n = Int(first.mDataByteSize) / 4
        let l = data.bindMemory(to: Float32.self, capacity: n)
        let r = rData.bindMemory(to: Float32.self, capacity: n)
        for i in 0..<n {
            sumL += Double(l[i] * l[i]); sumR += Double(r[i] * r[i]); sumLR += Double(l[i] * r[i]); sumDiff += Double((l[i] - r[i]) * (l[i] - r[i]))
            peakL = max(peakL, abs(l[i])); peakR = max(peakR, abs(r[i]))
        }
        frames += n
    }
}
AudioDeviceStart(device, procID)
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(device, procID)
if let procID { AudioDeviceDestroyIOProcID(device, procID) }

func db(_ v: Double) -> String { v > 0 ? String(format: "%6.1f dBFS", 20 * log10(v)) : "  -inf dBFS" }
guard frames > 0 else { print("no audio received"); exit(1) }
let rmsL = (sumL / Double(frames)).squareRoot(), rmsR = (sumR / Double(frames)).squareRoot()
let corr = sumL > 0 && sumR > 0 ? sumLR / (sumL.squareRoot() * sumR.squareRoot()) : 0
print("frames: \(frames) (\(String(format: "%.1f", Double(frames) / 44100)) s)")
print("channel 1 (left):  rms \(db(rmsL))   peak \(db(Double(peakL)))")
print("channel 2 (right): rms \(db(rmsR))   peak \(db(Double(peakR)))")
print(String(format: "correlation between channels: %.3f   (1 = identical, 0 = unrelated)", corr))
print("difference (L - R) rms: \(db((sumDiff / Double(frames)).squareRoot()))")
