import Foundation

/// 电子律动：四拍底鼓、二四拍军鼓、踩镲、贝斯、铺底和弦、琶音或合成器旋律；底鼓响时其他声部略微让开（侧链）。
/// 结构：前奏（底鼓、闭镲、铺底）→ 主体（全部）→ 尾声（去掉鼓，铺底与回声慢慢收）。
struct ElectronicPiece {
    enum Topline {
        /// 十六分音符琶音：按和弦音的顺序（下标）循环。
        case arpeggio([Int])
        /// 合成器旋律（按动机写）。
        case melody(rhythms: [MelodyWriter.Rhythm], plan: [(rhythm: Int, contour: Int)], center: Int)
    }

    let tempo: Tempo
    let scale: Scale
    let chords: [Chord]          // 每小节一个
    let bassPattern: [(Double, Double, Int)]   // (拍位, 时值, 相对根音的半音)
    let topline: Topline
    let introBars: Int
    let outroBars: Int
    let openHats: Bool
    let seed: UInt64

    func render(seconds: Double) -> Stereo {
        var rng = RNG(seed: seed)
        var drums = Stereo(seconds: seconds)
        var music = Stereo(seconds: seconds)
        let bars = chords.count
        let fullFrom = introBars, fullUntil = bars - outroBars
        let kick = Drums.kick()
        var duck = [Float](repeating: 1, count: drums.count)

        for bar in 0..<bars {
            let start = Double(bar) * 4
            let full = bar >= fullFrom && bar < fullUntil
            // 鼓
            if bar < fullUntil {
                for beat in 0..<4 {
                    let at = tempo.sample(start + Double(beat))
                    drums.add(kick, at: at, gain: 0.95)
                    // 侧链：底鼓后 0.18 秒内其他声部压低
                    for i in 0..<samples(0.22) where at + i < duck.count {
                        let x = Float(i) / Float(samples(0.22))
                        duck[at + i] = min(duck[at + i], 0.45 + 0.55 * x * x)
                    }
                }
                for step in 0..<16 {
                    let at = tempo.sample(start + Double(step) * 0.25)
                    if openHats, step % 4 == 2, full {
                        drums.add(Drums.hat(open: true, rng: &rng), at: at, gain: 0.16, pan: 0.3)
                    } else if step % 2 == 0 || full {
                        let accent: Float = step % 4 == 2 ? 0.2 : step % 2 == 0 ? 0.12 : 0.07
                        drums.add(Drums.hat(open: false, rng: &rng), at: at, gain: accent, pan: 0.3)
                    }
                }
                if full {
                    for beat in [1.0, 3.0] {
                        drums.add(Drums.snare(rng: &rng), at: tempo.sample(start + beat), gain: 0.5, pan: -0.08)
                    }
                }
            }
            // 铺底和弦（全曲）
            let chord = chords[bar]
            let padNotes = chord.pitches.map { $0 + 12 }
            music.mix(offset(Synths.pad(padNotes, gate: tempo.seconds(4), rng: &rng), by: tempo.sample(start), length: music.count), gain: 1)
            // 贝斯（主体）
            if full {
                var root = chord.root
                while root > 45 { root -= 12 }
                while root < 33 { root += 12 }
                for (beat, length, offsetSemitones) in bassPattern {
                    let sound = Synths.bass(root + offsetSemitones, gate: tempo.seconds(length) * 0.9, velocity: 0.9)
                    music.add(sound, at: tempo.sample(start + beat), gain: 0.85)
                }
            }
        }

        // 主旋律层（主体段落）
        var top = Stereo(seconds: seconds)
        switch topline {
        case .arpeggio(let order):
            for bar in fullFrom..<fullUntil {
                let tones = chords[bar].pitches.map { $0 + 24 } + [chords[bar].pitches[0] + 36]
                for step in 0..<16 {
                    let pitch = tones[order[step % order.count] % tones.count]
                    let velocity: Float = step % 4 == 0 ? 0.9 : 0.65
                    top.add(Synths.pluck(pitch, velocity: velocity), at: tempo.sample(Double(bar) * 4 + Double(step) * 0.25),
                            gain: 1, pan: step % 2 == 0 ? -0.2 : 0.2)
                }
            }
        case .melody(let rhythms, let plan, let center):
            var writer = MelodyWriter(scale: scale, center: center, beatsPerBar: 4, rng: RNG(seed: seed &+ 5))
            let notes = writer.write(chords: chords, rhythms: rhythms, plan: plan, startBar: fullFrom)
            for note in notes where note.beat < Double(fullUntil) * 4 {
                let sound = Synths.bass(note.pitch, gate: tempo.seconds(note.length) * 0.8, velocity: note.velocity)
                top.add(sound, at: tempo.sample(note.beat), gain: 0.55, pan: 0.1)
                top.add(Synths.pluck(note.pitch + 12, velocity: note.velocity * 0.6), at: tempo.sample(note.beat), gain: 0.6, pan: -0.15)
            }
        }
        top = pingPongDelay(top, seconds: tempo.seconds(0.75), feedback: 0.45, mix: 0.45)
        music.mix(top, gain: 1)
        music.apply(duck)

        var mix = drums
        mix.mix(music, gain: 1)
        let wet = reverb(mix, roomSize: 0.8, damping: 0.45)
        mix.mix(wet, gain: 0.18)
        mix.finish(fadeOut: 4)
        return mix
    }

    private func offset(_ s: Stereo, by start: Int, length: Int) -> Stereo {
        var out = Stereo(seconds: Double(length) / sampleRate)
        out.add(s.left, at: start, gain: 0.7071, pan: -1)
        out.add(s.right, at: start, gain: 0.7071, pan: 1)
        return out
    }
}

enum ElectronicAlbum {
    /// 《零点出发》：a 小调，每分钟 124 拍，十六分音符琶音。
    static let departure = ElectronicPiece(
        tempo: Tempo(bpm: 124), scale: .minor(9),
        chords: ["Am", "Am", "F", "F", "C", "C", "G", "G", "Am", "Am", "F", "F", "C", "G"].map(chord),
        bassPattern: [(0.5, 0.5, 0), (1.5, 0.5, 0), (2.5, 0.5, 12), (3.5, 0.5, 0)],
        topline: .arpeggio([0, 1, 2, 3, 2, 1, 0, 2, 0, 1, 2, 3, 2, 3, 1, 2]),
        introBars: 2, outroBars: 2, openHats: false, seed: 701)

    /// 《城市脉搏》：d 小调，每分钟 118 拍，合成器旋律（配有歌词）。
    static let pulse = ElectronicPiece(
        tempo: Tempo(bpm: 118), scale: .minor(2),
        chords: ["Dm", "Bb", "F", "C", "Dm", "Bb", "F", "C", "Gm", "Bb", "F", "C", "Dm"].map(chord),
        bassPattern: [(0, 0.5, 0), (0.75, 0.5, 0), (1.5, 0.5, 7), (2.5, 0.5, 0), (3, 0.5, 12), (3.5, 0.5, 0)],
        topline: .melody(rhythms: [[(0, 1), (1, 0.5), (1.5, 1), (2.5, 1.5), (4, 0.5), (4.5, 0.5), (5, 1), (6, 2)],
                                   [(0, 0.5), (0.5, 0.5), (1, 1), (2, 2), (4, 1), (5, 1), (6, 2)]],
                         plan: [(0, 0), (1, 1), (0, 0), (1, 2)], center: 69),
        introBars: 2, outroBars: 3, openHats: true, seed: 802)

    /// 《霓虹回声》：e 小调，每分钟 128 拍，开镲与长回声琶音。
    static let echoes = ElectronicPiece(
        tempo: Tempo(bpm: 128), scale: .minor(4),
        chords: ["Em", "C", "G", "D", "Em", "C", "G", "D", "Em", "C", "G", "D", "Em", "Em"].map(chord),
        bassPattern: [(0, 0.25, 0), (0.5, 0.25, 0), (0.75, 0.25, 12), (1.5, 0.25, 0), (2, 0.25, 0), (2.5, 0.25, 7), (3, 0.25, 0), (3.5, 0.5, 12)],
        topline: .arpeggio([0, 2, 1, 3, 0, 2, 1, 3, 2, 1, 0, 3, 2, 1, 3, 2]),
        introBars: 2, outroBars: 2, openHats: true, seed: 903)

    static func chord(_ name: String) -> Chord {
        let roots: [String: Int] = ["C": 48, "D": 50, "E": 52, "F": 53, "G": 55, "A": 57, "B": 59]
        let flat = name.dropFirst().hasPrefix("b")
        let minor = name.hasSuffix("m")
        var base = roots[String(name.prefix(1))] ?? 48
        if flat { base -= 1 }
        if base > 55 { base -= 12 }
        return triad(name, base, minor: minor)
    }
}
