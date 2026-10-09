import Foundation

/// 作曲用的乐理工具：音阶、和弦、按动机写旋律。

/// 一个音符（时间以拍为单位）。
struct Note {
    var beat: Double
    var length: Double
    var pitch: Int
    var velocity: Float
}

/// 调式音阶。级数用“绝对级数”：0 是中央 C 所在八度下面那个八度的主音（MIDI 主音 + 12×八度）。
struct Scale {
    let tonic: Int          // 主音的音级（0 = C）
    let steps: [Int]

    static func major(_ tonic: Int) -> Scale { Scale(tonic: tonic, steps: [0, 2, 4, 5, 7, 9, 11]) }
    static func minor(_ tonic: Int) -> Scale { Scale(tonic: tonic, steps: [0, 2, 3, 5, 7, 8, 10]) }

    func midi(_ degree: Int) -> Int {
        let octave = Int((Double(degree) / 7).rounded(.down))
        let index = degree - octave * 7
        return tonic + 12 * octave + steps[index]
    }

    /// 离给定音高最近的音阶级数。
    func degree(near pitch: Int) -> Int {
        var best = 0, bestDistance = Int.max
        let guess = (pitch - tonic) * 7 / 12
        for d in (guess - 3)...(guess + 3) {
            let distance = abs(midi(d) - pitch)
            if distance < bestDistance { best = d; bestDistance = distance }
        }
        return best
    }
}

/// 一小节的和弦：音级集合（用于找和弦音）与具体音高（用于伴奏）。
struct Chord {
    let name: String
    let pitches: [Int]
    var pitchClasses: Set<Int> { Set(pitches.map { (($0 % 12) + 12) % 12 }) }
    var root: Int { pitches[0] }
}

/// 常用和弦（根位三和弦，`base` 为根音的 MIDI 音高）。
func triad(_ name: String, _ base: Int, minor: Bool = false, seventh: Bool = false) -> Chord {
    var p = [base, base + (minor ? 3 : 4), base + 7]
    if seventh { p.append(base + (minor ? 10 : 11)) }
    return Chord(name: name, pitches: p)
}

/// 旋律写法：先随机生成一个两小节的“动机轮廓”（相邻音的级数走向），再按乐句结构（A A' B A″）在各小节和弦上套用，
/// 强拍落在和弦音上，乐句收尾落在主音或和弦根音上。重复 + 变化，听起来像一首曲子而不是乱弹。
struct MelodyWriter {
    let scale: Scale
    let center: Int                 // 旋律大致所在的音高
    let beatsPerBar: Double
    var rng: RNG

    /// 一个乐句（2 小节）的节奏：每个音的 (拍位, 时值)。
    typealias Rhythm = [(Double, Double)]

    mutating func contour(count: Int) -> [Int] {
        var out = [0]
        var direction = rng.chance(0.5) ? 1 : -1
        while out.count < count {
            let r = rng.float()
            var step = r < 0.55 ? 1 : r < 0.8 ? 2 : r < 0.9 ? 0 : 3
            if rng.chance(0.3) { direction = -direction }
            step *= direction
            var next = out.last! + step
            if next > 5 { next -= 2 * abs(step) ; direction = -1 }
            if next < -4 { next += 2 * abs(step); direction = 1 }
            out.append(next)
        }
        return out
    }

    /// 按乐句结构写整段旋律。`chords` 每小节一个；`rhythms` 是可选的几种乐句节奏；`plan` 每个乐句用哪种节奏、哪种轮廓。
    mutating func write(chords: [Chord], rhythms: [Rhythm], plan: [(rhythm: Int, contour: Int)], startBar: Int = 0) -> [Note] {
        var contours: [Int: [Int]] = [:]
        var notes: [Note] = []
        var previous = center
        for (phraseIndex, phrase) in plan.enumerated() {
            let rhythm = rhythms[phrase.rhythm]
            let shape = contours[phrase.contour] ?? contour(count: rhythm.count)
            contours[phrase.contour] = shape
            let firstBar = startBar + phraseIndex * 2
            guard firstBar < chords.count else { break }
            // 乐句第一个音：本小节和弦音里离上一个音最近的
            let startChord = chords[firstBar]
            var anchor = scale.degree(near: previous)
            anchor = snap(anchor, to: startChord, preferring: previous)
            let isLastPhrase = phraseIndex == plan.count - 1
            for (i, (beat, length)) in rhythm.enumerated() {
                let barOffset = Int(beat / beatsPerBar)
                let bar = min(chords.count - 1, firstBar + barOffset)
                var degree = anchor + shape[i]
                let strong = beat.truncatingRemainder(dividingBy: 1) == 0 && Int(beat) % 2 == 0
                if strong || length >= 1.5 { degree = snap(degree, to: chords[bar], preferring: previous) }
                // 乐句最后一个音：落在和弦根音（全曲最后落主音）
                if i == rhythm.count - 1 {
                    let target = isLastPhrase ? scale.tonic : ((chords[bar].root % 12) + 12) % 12
                    degree = nearestDegree(withPitchClass: target, around: degree)
                }
                var pitch = scale.midi(degree)
                while pitch > center + 10 { pitch -= 12 }
                while pitch < center - 9 { pitch += 12 }
                let accent: Float = strong ? 0.85 : 0.68
                notes.append(Note(beat: Double(firstBar) * beatsPerBar + beat, length: length, pitch: pitch,
                                  velocity: accent + rng.float() * 0.1))
                previous = pitch
            }
        }
        return notes
    }

    private func snap(_ degree: Int, to chord: Chord, preferring _: Int) -> Int {
        let classes = chord.pitchClasses
        for d in [degree, degree - 1, degree + 1, degree - 2, degree + 2] where classes.contains(((scale.midi(d) % 12) + 12) % 12) {
            return d
        }
        return degree
    }

    private func nearestDegree(withPitchClass pc: Int, around degree: Int) -> Int {
        for d in [degree, degree - 1, degree + 1, degree - 2, degree + 2, degree - 3, degree + 3]
        where ((scale.midi(d) % 12) + 12) % 12 == pc { return d }
        return degree
    }
}

/// 拍子与时间的换算。
struct Tempo {
    let bpm: Double
    var secondsPerBeat: Double { 60 / bpm }
    func sample(_ beat: Double) -> Int { Int(beat * secondsPerBeat * sampleRate) }
    func seconds(_ beats: Double) -> Double { beats * secondsPerBeat }
}
