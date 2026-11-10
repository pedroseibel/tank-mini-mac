import CoreAudio
import Foundation
import TankMiniCore

// tankctl tuner-cal: works out what the pedal's tuner bytes mean.
//
// It records the pedal's USB audio, measures the pitch of what is being played, and
// prints that next to the raw tuner bytes read at the same moment. Comparing the two
// columns gives the note numbering and the scale of the deviation byte for a firmware.
// Read-only: the tuner must already be on (open it in the app). Nothing is played.

private final class AudioTap {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var device = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    init?() {
        var a = AudioTap.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        guard let found = ids.first(where: { id in
            guard AudioTap.string(id, kAudioObjectPropertyManufacturer).lowercased().contains("jieli") else { return false }
            var s = AudioTap.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var n: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n)
            return n > 0
        }) else { return nil }
        device = found
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / 4 / channels
            let p = data.bindMemory(to: Float32.self, capacity: frames * channels)
            self.lock.lock()
            for i in 0..<frames { self.samples.append(p[i * channels]) }
            if self.samples.count > 32768 { self.samples.removeFirst(self.samples.count - 32768) }
            self.lock.unlock()
        }
        AudioDeviceStart(device, procID)
    }

    deinit {
        AudioDeviceStop(device, procID)
        if let procID { AudioDeviceDestroyIOProcID(device, procID) }
    }

    func latest(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples.count >= count ? Array(samples.suffix(count)) : []
    }
}

/// Fundamental frequency of a guitar or bass note, by normalised difference function (YIN).
private func pitch(_ x: [Float], sampleRate: Double = 44100) -> (hz: Double, rmsDB: Double)? {
    guard x.count >= 8192 else { return nil }
    let mean = x.reduce(0, +) / Float(x.count)
    let s = x.map { $0 - mean }
    let rms = (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    let rmsDB = rms > 0 ? 20 * log10(Double(rms)) : -200
    guard rmsDB > -55 else { return nil }
    let minLag = Int(sampleRate / 500), maxLag = Int(sampleRate / 35) // 35 Hz (low B bass) ... 500 Hz
    let window = s.count - maxLag
    var d = [Double](repeating: 0, count: maxLag + 1)
    for lag in 1...maxLag {
        var sum: Float = 0
        for i in 0..<window { let diff = s[i] - s[i + lag]; sum += diff * diff }
        d[lag] = Double(sum)
    }
    var running = 0.0
    var normalised = [Double](repeating: 1, count: maxLag + 1)
    for lag in 1...maxLag {
        running += d[lag]
        normalised[lag] = running > 0 ? d[lag] * Double(lag) / running : 1
    }
    var best = -1
    var lag = minLag
    while lag < maxLag {
        if normalised[lag] < 0.12 {
            while lag + 1 < maxLag, normalised[lag + 1] < normalised[lag] { lag += 1 }
            best = lag
            break
        }
        lag += 1
    }
    if best < 0 {
        best = (minLag..<maxLag).min { normalised[$0] < normalised[$1] } ?? -1
        guard best > 0, normalised[best] < 0.35 else { return nil }
    }
    var refined = Double(best)
    if best > 1, best < maxLag {
        let a = normalised[best - 1], b = normalised[best], c = normalised[best + 1]
        let denominator = a - 2 * b + c
        if denominator != 0 { refined += 0.5 * (a - c) / denominator }
    }
    return (sampleRate / refined, rmsDB)
}

private let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func runTunerCalibration(pedal: Pedal, seconds: Double) {
    guard let tap = AudioTap() else { print("pedal audio input not found"); return }
    print("  time  tuner bytes        | measured pitch")
    let start = Date()
    var lastLine = ""
    var misses = 0
    while Date().timeIntervalSince(start) < seconds {
        Thread.sleep(forTimeInterval: 0.1)
        guard let t = try? pedal.read(.dev, Address.tuner, 6) else { misses += 1; continue }
        var measured = "(no pitch in the audio)"
        if let p = pitch(tap.latest(8192)) {
            let midi = 69 + 12 * log2(p.hz / 440)
            let nearest = Int(midi.rounded())
            let cents = (midi - Double(nearest)) * 100
            measured = String(format: "%7.2f Hz  %@%d  %+6.1f cents  (%.0f dBFS)", p.hz, names[((nearest % 12) + 12) % 12], nearest / 12 - 1, cents, p.rmsDB)
        }
        let line = "\(t.hex) | \(measured)"
        // Skip exact repeats of an idle line to keep the log short.
        if line == lastLine && measured.hasPrefix("(") { continue }
        lastLine = line
        print(String(format: "%6.2f  %@", Date().timeIntervalSince(start), line))
    }
    if misses > 0 { print("\(misses) readings were lost (another program was using the pedal at the same time)") }
}
