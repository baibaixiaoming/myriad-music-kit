import Foundation

/// 各种音色：钢琴（加法合成）、木吉他（弹拨弦模型）、口哨般的旋律音、电子鼓、贝斯、铺底和弦、拨奏合成器。

enum Piano {
    /// 一个钢琴音：多个泛音，高泛音衰减更快、略带失谐；两根弦微微走音产生拍音；起音带一点击弦噪声。
    static func note(_ pitch: Int, gate: Double, velocity: Float, rng: inout RNG) -> [Float] {
        let f = midiFrequency(Double(pitch))
        let release = 0.35
        let total = min(gate + release, 5)
        let n = samples(total)
        var out = [Float](repeating: 0, count: n)
        let baseDecay = 2.8 * pow(261.6 / f, 0.55)            // 低音更长
        let brightness = 0.6 + Double(velocity) * 0.8
        let inharmonic = 0.00035
        let gateSamples = samples(gate)
        for partial in 1...10 {
            let pf = Double(partial) * f * sqrt(1 + inharmonic * Double(partial * partial))
            guard pf < sampleRate / 2.2 else { break }
            let amp = pow(Double(partial), -1.25 - (1 - brightness) * 0.6) * (partial == 1 ? 1 : 0.85)
            let decay = baseDecay / (1 + 0.45 * Double(partial - 1))
            let releaseFactor = exp(-1 / sampleRate / 0.12)
            let decayFactor = exp(-1 / sampleRate / decay)
            for (k, detune) in [1.0, 1.0006].enumerated() {
                // 用旋转的复数代替逐点 sin：快得多，结果相同
                let w = 2 * .pi * pf * detune / sampleRate
                let (cw, sw) = (cos(w), sin(w))
                let start = k == 0 ? 0.0 : Double(rng.float()) * 2 * .pi
                var (re, im) = (cos(start), sin(start))
                var env = amp
                for i in 0..<n {
                    out[i] += Float(env * im) * 0.5
                    (re, im) = (re * cw - im * sw, re * sw + im * cw)
                    env *= i > gateSamples ? decayFactor * releaseFactor : decayFactor
                    if env < 0.00005 { break }
                }
            }
        }
        // 击弦：极短的滤波噪声
        var lp = OnePole(cutoff: min(6000, f * 8))
        for i in 0..<min(n, samples(0.012)) {
            let e = 1 - Float(i) / Float(samples(0.012))
            out[i] += lp.process(rng.bipolar()) * e * 0.25
        }
        // 起音 3 毫秒
        let attack = samples(0.003)
        for i in 0..<min(n, attack) { out[i] *= Float(i) / Float(attack) }
        let gain = velocity * velocity * 0.32
        return out.map { $0 * gain }
    }
}

enum Guitar {
    /// 弹拨弦（Karplus-Strong）：一段随机噪声在延时环里反复平均，越弹越圆润；小数延时用全通补齐，音准准确。
    /// `ring`：这根弦响多久（之后 25 毫秒内止音）。
    static func pluck(_ pitch: Int, ring: Double, velocity: Float, brightness: Double = 3200, rng: inout RNG) -> [Float] {
        let f = midiFrequency(Double(pitch))
        let p = sampleRate / f - 0.5
        let length = max(2, Int(p))
        let frac = Float(p - Double(length))
        let c = (1 - frac) / (1 + frac)
        var line = [Float](repeating: 0, count: length)
        var lp = OnePole(cutoff: brightness * Double(0.6 + velocity * 0.6))
        for i in 0..<length { line[i] = lp.process(rng.bipolar()) }
        let mean = line.reduce(0, +) / Float(length)
        for i in 0..<length { line[i] -= mean }
        let decay: Float = pitch < 52 ? 0.9985 : 0.997
        let n = samples(min(ring, 4) + 0.025)
        let stop = samples(min(ring, 4))
        var out = [Float](repeating: 0, count: n)
        var idx = 0, apX: Float = 0, apY: Float = 0
        var body = SVF(resonance: 1.2)
        for i in 0..<n {
            let cur = line[idx], next = line[(idx + 1) % length]
            let avg = decay * 0.5 * (cur + next)
            let ap = c * avg + apX - c * apY
            apX = avg; apY = ap
            line[idx] = ap
            idx = (idx + 1) % length
            // 琴身：在 110 赫兹附近加一点共鸣
            let (_, band, _) = body.process(cur, cutoff: 110)
            var v = cur + band * 0.15
            if i > stop { v *= 1 - Float(i - stop) / Float(n - stop) }
            out[i] = v
        }
        return out.map { $0 * velocity * 0.5 }
    }

    /// 一次扫弦：按弦序依次拨，下扫从低音弦到高音弦，上扫反过来且只扫高音几根、力度轻一些。
    static func strum(_ chord: [Int], down: Bool, velocity: Float, ring: Double, into mix: inout Stereo, at start: Int, rng: inout RNG) {
        let strings = down ? chord : Array(chord.suffix(4).reversed())
        let spacing = down ? 0.011 : 0.008
        for (k, pitch) in strings.enumerated() {
            let v = velocity * (down ? 1 : 0.7) * (0.85 + rng.float() * 0.15)
            let sound = pluck(pitch, ring: ring - Double(k) * spacing, velocity: v, rng: &rng)
            let pan = Float(k) / Float(max(1, strings.count - 1)) * 0.5 - 0.25
            mix.add(sound, at: start + samples(Double(k) * spacing), gain: 0.55, pan: pan)
        }
    }
}

enum Lead {
    /// 口哨般的旋律音：正弦为主，略加二、三次泛音，带慢起音与颤音。
    static func whistle(_ pitch: Int, gate: Double, velocity: Float, phase: Double = 0) -> [Float] {
        let f = midiFrequency(Double(pitch))
        let n = samples(gate + 0.25)
        let g = samples(gate)
        var out = [Float](repeating: 0, count: n)
        var osc = Oscillator(phase: phase)
        var p2 = 0.0, p3 = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let vibrato = 1 + 0.004 * sin(2 * .pi * 5.2 * t) * min(1, t / 0.35)
            let s = osc.sine(f * vibrato)
            p2 += 2 * f * vibrato / sampleRate; p3 += 3 * f * vibrato / sampleRate
            let v = s + 0.12 * Float(sin(2 * .pi * p2)) + 0.04 * Float(sin(2 * .pi * p3))
            out[i] = v * adsr(i, attack: 0.06, decay: 0.4, sustain: 0.75, release: 0.12, gate: g)
        }
        return out.map { $0 * velocity * 0.32 }
    }
}

enum Drums {
    /// 底鼓：音高从约 150 赫兹快速滑到 48 赫兹的正弦，再加一点点击声。
    static func kick() -> [Float] {
        let n = samples(0.45)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = 48 + 105 * exp(-t / 0.035)
            phase += f / sampleRate
            out[i] = Float(sin(2 * .pi * phase) * exp(-t / 0.16))
            if i < samples(0.004) { out[i] += Float(0.4 * (1 - t / 0.004)) }
        }
        return out
    }

    /// 军鼓（拍手般）：带通噪声加一点 190 赫兹的鼓皮声。
    static func snare(rng: inout RNG) -> [Float] {
        let n = samples(0.28)
        var out = [Float](repeating: 0, count: n)
        var f = SVF(resonance: 0.9)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let (_, band, high) = f.process(rng.bipolar(), cutoff: 1800)
            let noise = (band * 0.7 + high * 0.3) * Float(exp(-t / 0.07))
            let tone = Float(sin(2 * .pi * 190 * t) * exp(-t / 0.05)) * 0.5
            out[i] = noise * 0.9 + tone
        }
        return out
    }

    /// 踩镲：高通噪声，闭镲很短、开镲长一些。
    static func hat(open: Bool, rng: inout RNG) -> [Float] {
        let length = open ? 0.32 : 0.05
        let n = samples(length)
        var out = [Float](repeating: 0, count: n)
        var f = SVF(resonance: 0.8)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let (_, _, high) = f.process(rng.bipolar(), cutoff: 7500)
            out[i] = high * Float(exp(-t / (open ? 0.12 : 0.018)))
        }
        return out
    }

    /// 沙锤：轻的高通噪声，起音稍慢。
    static func shaker(rng: inout RNG) -> [Float] {
        let n = samples(0.09)
        var out = [Float](repeating: 0, count: n)
        var f = SVF(resonance: 0.7)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let (_, _, high) = f.process(rng.bipolar(), cutoff: 5500)
            let env = min(1, t / 0.015) * exp(-t / 0.03)
            out[i] = high * Float(env)
        }
        return out
    }
}

enum Synths {
    /// 贝斯：两只略走音的锯齿波过低通，滤波随每个音的包络张开再合上。
    static func bass(_ pitch: Int, gate: Double, velocity: Float) -> [Float] {
        let f = midiFrequency(Double(pitch))
        let n = samples(gate + 0.08)
        let g = samples(gate)
        var out = [Float](repeating: 0, count: n)
        var a = Oscillator(), b = Oscillator(phase: 0.3), sub = Oscillator()
        var filter = SVF(resonance: 1.4)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let raw = a.saw(f) * 0.5 + b.saw(f * 1.004) * 0.5 + sub.sine(f / 2) * 0.6
            let cutoff = 180 + 1400 * exp(-t / 0.09) * Double(velocity)
            let (low, _, _) = filter.process(raw, cutoff: cutoff)
            out[i] = low * adsr(i, attack: 0.004, decay: 0.2, sustain: 0.7, release: 0.05, gate: g)
        }
        return out.map { $0 * velocity * 0.55 }
    }

    /// 铺底和弦：每个音三只走音的锯齿波，慢起音，过较暗的低通。
    static func pad(_ chord: [Int], gate: Double, rng: inout RNG) -> Stereo {
        var out = Stereo(seconds: gate + 0.8)
        let g = samples(gate)
        for (k, pitch) in chord.enumerated() {
            let f = midiFrequency(Double(pitch))
            var voice = [Float](repeating: 0, count: out.count)
            var oscs = (0..<3).map { _ in Oscillator(phase: Double(rng.float())) }
            let detunes = [1.0, 1.0035, 0.9968]
            var filter = SVF(resonance: 0.8)
            for i in 0..<out.count {
                var s: Float = 0
                for j in 0..<3 { s += oscs[j].saw(f * detunes[j]) }
                let t = Double(i) / sampleRate
                let (low, _, _) = filter.process(s / 3, cutoff: 900 + 500 * sin(2 * .pi * 0.15 * t))
                voice[i] = low * adsr(i, attack: 0.6, decay: 1.5, sustain: 0.8, release: 0.6, gate: g)
            }
            out.add(voice, at: 0, gain: 0.16, pan: Float(k) / Float(max(1, chord.count - 1)) * 0.8 - 0.4)
        }
        return out
    }

    /// 拨奏合成器：方波过快速合上的低通，短促明亮（琶音用）。
    static func pluck(_ pitch: Int, velocity: Float) -> [Float] {
        let f = midiFrequency(Double(pitch))
        let n = samples(0.35)
        var out = [Float](repeating: 0, count: n)
        var osc = Oscillator()
        var filter = SVF(resonance: 2.2)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let (low, _, _) = filter.process(osc.square(f, width: 0.35), cutoff: 400 + 4200 * exp(-t / 0.06))
            out[i] = low * Float(exp(-t / 0.12)) * min(1, Float(t / 0.002))
        }
        return out.map { $0 * velocity * 0.3 }
    }
}
