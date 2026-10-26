import Accelerate

/// Loudness of audio with Accelerate: one vectorised RMS per frame instead of a scalar sum-of-squares loop. The speech
/// watch, a take's levels, a recording's speech regions and prosody all measure it.
enum Loudness {
    /// RMS of `window`-sample frames every `hop` samples; a frame that would run past the end is left out.
    static func frames(_ s: [Float], window: Int, hop: Int) -> [Float] {
        let w = max(1, window), h = max(1, hop)
        guard s.count >= w else { return [] }
        let n = (s.count - w) / h + 1
        var out = [Float](repeating: 0, count: n)
        s.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<n { vDSP_rmsqv(p.baseAddress! + i * h, 1, o.baseAddress! + i, vDSP_Length(w)) }
            }
        }
        return out
    }

    /// RMS of a whole buffer (0 when empty).
    static func rms(_ p: UnsafeBufferPointer<Float>) -> Float {
        guard let base = p.baseAddress, !p.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(base, 1, &r, vDSP_Length(p.count))
        return r
    }
}
