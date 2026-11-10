import AppKit

/// Short, soft sound cues, synthesised once: a rising two-note chime to
/// start, the same falling to stop, and a low double tap for a problem.
@MainActor
enum Cue {
    case start, stop, problem

    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard AppSettings.shared.sounds else { return }
        let key = "\(cue)"
        let sound = cache[key] ?? {
            let s = NSSound(data: wav(for: cue))
            s?.volume = 0.32
            cache[key] = s
            return s
        }()
        sound?.stop()
        sound?.play()
    }

    private static func wav(for cue: Cue) -> Data {
        switch cue {
        case .start: return synth([(1318.5, 0.055), (1760.0, 0.11)])
        case .stop: return synth([(1760.0, 0.055), (1318.5, 0.11)])
        case .problem: return synth([(392.0, 0.07), (0, 0.035), (329.6, 0.12)])
        }
    }

    /// Sine notes with a little second harmonic, a fast attack and an
    /// exponential release, as 16-bit mono WAV.
    private static func synth(_ notes: [(freq: Double, length: Double)]) -> Data {
        let rate = 44_100.0
        var samples: [Int16] = []
        var phase = 0.0
        for (freq, length) in notes {
            let n = Int(length * rate)
            for i in 0 ..< n {
                let t = Double(i) / rate
                let attack = min(1, t / 0.004)
                let release = exp(-t / (length * 0.45))
                phase += 2 * .pi * freq / rate
                let v = freq == 0 ? 0 : (sin(phase) * 0.82 + sin(phase * 2) * 0.18) * attack * release
                samples.append(Int16(max(-1, min(1, v * 0.6)) * Double(Int16.max)))
            }
        }
        // A short tail of silence keeps the end from clicking.
        samples.append(contentsOf: [Int16](repeating: 0, count: Int(0.02 * rate)))

        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: $0.count * 2)) }
        return data
    }
}
