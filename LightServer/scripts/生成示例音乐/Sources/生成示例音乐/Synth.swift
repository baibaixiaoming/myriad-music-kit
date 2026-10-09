import Foundation

/// 合成用的基本工具：立体声缓冲、随机数、包络、滤波、混响。全部自己写，不依赖音频素材。
let sampleRate: Double = 44100

/// 立体声缓冲（浮点）。
struct Stereo {
    var left: [Float]
    var right: [Float]

    init(seconds: Double) {
        let n = Int(seconds * sampleRate)
        left = [Float](repeating: 0, count: n)
        right = [Float](repeating: 0, count: n)
    }

    var count: Int { left.count }

    /// 把单声道信号按声像（-1 左 … 1 右）加到 `start` 处。
    mutating func add(_ mono: [Float], at start: Int, gain: Float, pan: Float = 0) {
        let angle = Double(pan + 1) * .pi / 4
        let gl = gain * Float(cos(angle)) * 1.414, gr = gain * Float(sin(angle)) * 1.414
        let end = min(count, start + mono.count)
        guard start < end else { return }
        for i in max(0, start) ..< end {
            let v = mono[i - start]
            left[i] += v * gl
            right[i] += v * gr
        }
    }

    mutating func mix(_ other: Stereo, gain: Float) {
        for i in 0 ..< min(count, other.count) {
            left[i] += other.left[i] * gain
            right[i] += other.right[i] * gain
        }
    }

    /// 逐点乘一条增益曲线（例如随底鼓的“压缩”起伏）。
    mutating func apply(_ curve: [Float]) {
        for i in 0 ..< min(count, curve.count) {
            left[i] *= curve[i]
            right[i] *= curve[i]
        }
    }

    /// 开头 20 毫秒淡入、结尾 `fadeOut` 秒淡出，再整体调到峰值 -1 dBFS。
    mutating func finish(fadeOut: Double) {
        let fadeIn = Int(0.02 * sampleRate)
        let outStart = count - Int(fadeOut * sampleRate)
        for i in 0 ..< count {
            var g: Float = 1
            if i < fadeIn { g = Float(i) / Float(fadeIn) }
            if i >= outStart {
                let x = Float(i - outStart) / Float(count - outStart)
                g *= (1 - x) * (1 - x)
            }
            left[i] *= g
            right[i] *= g
        }
        let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        guard peak > 0 else { return }
        let target: Float = 0.891   // -1 dBFS
        let scale = target / peak
        for i in 0 ..< count { left[i] *= scale; right[i] *= scale }
    }

    /// 转成 16 位整数（交错），加三角分布抖动。
    func int16Interleaved(rng: inout RNG) -> [Int16] {
        var out = [Int16](repeating: 0, count: count * 2)
        for i in 0 ..< count {
            for (c, v) in [left[i], right[i]].enumerated() {
                let dither = (rng.float() - rng.float()) / 32768
                let s = max(-1, min(1, v + dither))
                out[i * 2 + c] = Int16((s * 32767).rounded())
            }
        }
        return out
    }
}

/// 可重复的随机数（同一个种子每次生成一样的音乐）。
struct RNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// 0 到 1。
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    /// -1 到 1。
    mutating func bipolar() -> Float { float() * 2 - 1 }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func chance(_ p: Float) -> Bool { float() < p }
}

func midiFrequency(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

func samples(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

/// 一阶低通（越小越暗）。
struct OnePole {
    var a: Float
    var z: Float = 0
    init(cutoff: Double) { a = Float(1 - exp(-2 * .pi * cutoff / sampleRate)) }
    mutating func process(_ x: Float) -> Float { z += a * (x - z); return z }
}

/// 状态变量滤波（低通 / 带通 / 高通），可逐点改截止频率。
struct SVF {
    var low: Float = 0, band: Float = 0
    var q: Float
    init(resonance q: Float = 0.7) { self.q = q }
    /// 返回 (低通, 带通, 高通)。
    mutating func process(_ x: Float, cutoff: Double) -> (Float, Float, Float) {
        let f = Float(2 * sin(.pi * min(cutoff, sampleRate / 6) / sampleRate))
        let high = x - low - band / q
        band += f * high
        low += f * band
        return (low, band, high)
    }
}

/// 带限锯齿波与方波（PolyBLEP，减少刺耳的混叠）。
struct Oscillator {
    var phase: Double
    init(phase: Double = 0) { self.phase = phase }

    private static func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    mutating func saw(_ freq: Double) -> Float {
        let dt = freq / sampleRate
        let v = 2 * phase - 1 - Self.blep(phase, dt)
        phase += dt
        if phase >= 1 { phase -= 1 }
        return Float(v)
    }

    mutating func square(_ freq: Double, width: Double = 0.5) -> Float {
        let dt = freq / sampleRate
        var v: Double = phase < width ? 1 : -1
        v += Self.blep(phase, dt)
        var t2 = phase - width
        if t2 < 0 { t2 += 1 }
        v -= Self.blep(t2, dt)
        phase += dt
        if phase >= 1 { phase -= 1 }
        return Float(v)
    }

    mutating func sine(_ freq: Double) -> Float {
        let v = sin(2 * .pi * phase)
        phase += freq / sampleRate
        if phase >= 1 { phase -= 1 }
        return Float(v)
    }
}

/// 线性起音 + 指数衰减到持续电平 + 释放。
func adsr(_ i: Int, attack: Double, decay: Double, sustain: Float, release: Double, gate: Int) -> Float {
    let t = Double(i) / sampleRate
    let g = Double(gate) / sampleRate
    func held(_ t: Double) -> Float {
        if t < attack { return Float(t / attack) }
        return sustain + (1 - sustain) * Float(exp(-(t - attack) / max(decay, 0.001)))
    }
    if t < g { return held(t) }
    return held(g) * Float(exp(-(t - g) / max(release, 0.001)))
}

/// 简单的立体声混响（Schroeder：并联梳状 + 串联全通，左右声道延时略不同）。
func reverb(_ input: Stereo, roomSize: Float = 0.82, damping: Float = 0.3) -> Stereo {
    let combTimes = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    let allpassTimes = [556, 441, 341, 225]
    var out = input
    for channel in 0 ..< 2 {
        let x = channel == 0 ? input.left : input.right
        let spread = channel == 0 ? 0 : 23
        var y = [Float](repeating: 0, count: x.count)
        for t in combTimes {
            let n = t + spread
            var buf = [Float](repeating: 0, count: n)
            var idx = 0
            var store: Float = 0
            for i in 0 ..< x.count {
                let o = buf[idx]
                store = o * (1 - damping) + store * damping
                buf[idx] = x[i] * 0.015 + store * roomSize
                idx += 1; if idx == n { idx = 0 }
                y[i] += o
            }
        }
        for t in allpassTimes {
            let n = t + spread
            var buf = [Float](repeating: 0, count: n)
            var idx = 0
            for i in 0 ..< y.count {
                let b = buf[idx]
                let o = -y[i] + b
                buf[idx] = y[i] + b * 0.5
                idx += 1; if idx == n { idx = 0 }
                y[i] = o
            }
        }
        if channel == 0 { out.left = y } else { out.right = y }
    }
    return out
}

/// 立体声延时回声（左右交替），给电子音色加空间。
func pingPongDelay(_ input: Stereo, seconds: Double, feedback: Float, mix: Float) -> Stereo {
    let d = samples(seconds)
    var out = input
    var lineL = [Float](repeating: 0, count: input.count), lineR = lineL
    for i in 0 ..< input.count {
        let lo = i >= d ? lineL[i - d] : 0
        let ro = i >= d ? lineR[i - d] : 0
        lineL[i] = (input.left[i] + input.right[i]) * 0.5 + ro * feedback
        lineR[i] = lo * feedback
        out.left[i] += lo * mix
        out.right[i] += ro * mix
    }
    return out
}
