import AppKit

/// Warm, felt-damped sound cues in the midrange (C4–C5, 247–523 Hz),
/// designed to stay gentle and fatigue-free across intensive daily dictation.
///
/// The cues trace a calm F-major pentatonic arc across a session:
/// - `start`: soft rising fourth (C4 → F4, mic live)
/// - `stop`: cushioned upward nudge (F4 → G4, captured and entering the pipeline)
/// - `switchToTranslate`: soft rising third (F4 → A4, added Translate mid-session)
/// - `switchToPolish`: soft settling third (A4 → F4, switched back to Polish mid-session)
/// - `stage`: single feather-soft wooden droplet (A4, Polish → Translate handoff)
/// - `done`: warm open fifth (F4 → C5, text landed)
/// - `doneBig`: plush F-major bloom (C4 → F4 → A4 → C5) for long or translated takes
/// - `cancel`: muted step down (D4 → C4)
/// - `problem`: calm low double tap (E4 → B3)
@MainActor
enum Cue {
    case start, stop, switchToTranslate, switchToPolish, stage, done, doneBig, cancel, problem

    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: Cue) {
        guard AppSettings.shared.sounds else { return }
        let key = "\(cue)"
        let sound = cache[key] ?? {
            let s = NSSound(data: wav(for: cue))
            s?.volume = volume(for: cue)
            cache[key] = s
            return s
        }()
        sound?.stop()
        sound?.play()
    }

    private static func volume(for cue: Cue) -> Float {
        switch cue {
        case .start: return 0.25
        case .stop: return 0.19
        case .switchToTranslate, .switchToPolish: return 0.16
        case .stage: return 0.15
        case .done: return 0.21
        case .doneBig: return 0.22
        case .cancel: return 0.18
        case .problem: return 0.22
        }
    }

    private struct Note {
        let at: Double          // onset in seconds
        let freq: Double        // fundamental frequency in Hz
        let length: Double      // envelope length in seconds
        let amp: Double         // relative amplitude
        var attack: Double = 0.014
        var warmth: Double = 0.0 // subtle sub-octave body for chord resolutions
    }

    private static func wav(for cue: Cue) -> Data {
        switch cue {
        case .start:
            // C4 -> F4: soft welcoming rising fourth
            return synth([
                Note(at: 0.000, freq: 261.63, length: 0.130, amp: 0.44),
                Note(at: 0.058, freq: 349.23, length: 0.180, amp: 0.50),
            ])
        case .stop:
            // F4 -> G4: cushioned handoff into the pipeline
            return synth([
                Note(at: 0.000, freq: 349.23, length: 0.105, amp: 0.36),
                Note(at: 0.048, freq: 392.00, length: 0.145, amp: 0.40),
            ])
        case .switchToTranslate:
            // F4 -> A4: light rising third when enabling Translate mid-session
            return synth([
                Note(at: 0.000, freq: 349.23, length: 0.095, amp: 0.36, attack: 0.014),
                Note(at: 0.044, freq: 440.00, length: 0.140, amp: 0.40, attack: 0.015),
            ])
        case .switchToPolish:
            // A4 -> F4: soft settling third when switching back to Polish mid-session
            return synth([
                Note(at: 0.000, freq: 440.00, length: 0.095, amp: 0.36, attack: 0.014),
                Note(at: 0.044, freq: 349.23, length: 0.140, amp: 0.40, attack: 0.015),
            ])
        case .stage:
            // Single feather-soft A4 droplet when Polish hands off to Translate
            return synth([
                Note(at: 0.000, freq: 440.00, length: 0.130, amp: 0.42, attack: 0.016),
            ])
        case .done:
            // F4 -> C5: warm open fifth resolution
            return synth([
                Note(at: 0.000, freq: 349.23, length: 0.190, amp: 0.40, attack: 0.014, warmth: 0.05),
                Note(at: 0.056, freq: 523.25, length: 0.260, amp: 0.46, attack: 0.016, warmth: 0.05),
            ])
        case .doneBig:
            // C4 -> F4 -> A4 -> C5: plush midrange bloom, never piercing
            return synth([
                Note(at: 0.000, freq: 261.63, length: 0.220, amp: 0.30, attack: 0.016, warmth: 0.06),
                Note(at: 0.048, freq: 349.23, length: 0.240, amp: 0.34, attack: 0.016, warmth: 0.05),
                Note(at: 0.096, freq: 440.00, length: 0.260, amp: 0.36, attack: 0.016, warmth: 0.04),
                Note(at: 0.148, freq: 523.25, length: 0.340, amp: 0.40, attack: 0.018, warmth: 0.04),
            ])
        case .cancel:
            // D4 -> C4: soft muted step down
            return synth([
                Note(at: 0.000, freq: 293.66, length: 0.095, amp: 0.38),
                Note(at: 0.048, freq: 261.63, length: 0.135, amp: 0.40),
            ])
        case .problem:
            // E4 -> B3: calm muted double knock
            return synth([
                Note(at: 0.000, freq: 329.63, length: 0.115, amp: 0.44),
                Note(at: 0.115, freq: 246.94, length: 0.175, amp: 0.46),
            ])
        }
    }

    /// Renders overlapping felt-damped marimba tones as 16-bit mono WAV.
    /// Uses a raised-cosine attack (zero click), fast-damped wooden 2nd harmonic
    /// with no sharp upper overtones, subtle pitch bloom, and a gentle 1.4 kHz
    /// low-pass smoothing pass so nothing ever hits the harsh 2–5 kHz band.
    private static func synth(_ notes: [Note]) -> Data {
        let rate = 44_100.0
        let end = (notes.map { $0.at + $0.length }.max() ?? 0.1) + 0.04
        var mix = [Double](repeating: 0, count: Int(ceil(end * rate)))
        let fadeSamples = Int(0.025 * rate)

        for note in notes where note.freq > 0 {
            let startIdx = Int(note.at * rate)
            let count = Int(note.length * rate)
            let tau = note.length * 0.32
            let attack = max(0.008, note.attack)
            let pitchTau = 0.018
            let pitchDip = 0.005 // soft ~8.6-cent mallet bloom into exact pitch

            for i in 0 ..< count {
                let idx = startIdx + i
                guard idx < mix.count else { break }
                let t = Double(i) / rate

                // C1-smooth raised-cosine attack eliminates onset clicks completely.
                let attackEnv = t < attack ? 0.5 * (1.0 - cos(.pi * (t / attack))) : 1.0
                let decayEnv = exp(-t / tau)
                let tailFade: Double = {
                    let remain = count - i
                    guard remain < fadeSamples else { return 1.0 }
                    return 0.5 * (1.0 - cos(.pi * Double(remain) / Double(fadeSamples)))
                }()
                let env = attackEnv * decayEnv * tailFade

                // Exact phase integral of f(t) = freq * (1 - pitchDip * exp(-t / pitchTau)).
                let phase = 2 * .pi * note.freq * (t + pitchDip * pitchTau * (exp(-t / pitchTau) - 1.0))

                // Felt-damped wood: round fundamental, brief wooden 2nd harmonic that
                // vanishes within ~20 ms, optional sub-octave warmth, zero 3rd+ overtones.
                let woodOver = 0.075 * exp(-t / 0.020)
                let sub = note.warmth > 0 ? note.warmth * exp(-t / (tau * 0.85)) * sin(phase * 0.5) : 0.0
                let wave = sin(phase) * 0.90 + sin(phase * 2.0) * woodOver + sub
                mix[idx] += wave * env * note.amp
            }
        }

        // Gentle 1-pole low-pass at 1.4 kHz keeps the tail plush and removes any treble edge.
        let rc = 1.0 / (2.0 * .pi * 1400.0)
        let alpha = (1.0 / rate) / (rc + (1.0 / rate))
        var lp = 0.0
        for i in mix.indices {
            lp += alpha * (mix[i] - lp)
            mix[i] = lp
        }

        // Soft ceiling so overlapping chords never clip.
        let samples: [Int16] = mix.map { v in
            let clamped = tanh(v * 0.92)
            return Int16(max(-1, min(1, clamped)) * Double(Int16.max))
        }

        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer {
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: $0.count * 2))
        }
        return data
    }
}
