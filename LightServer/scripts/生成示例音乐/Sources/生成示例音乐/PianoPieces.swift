import Foundation

/// 钢琴小品：左手分解和弦（或圆舞曲伴奏），右手按动机写的旋律，最后一小节停在主和弦上。
struct PianoPiece {
    enum LeftHand { case arpeggio, waltz, walking }

    let tempo: Tempo
    let beatsPerBar: Double
    let scale: Scale
    let chords: [Chord]          // 每小节一个（最后一个是结尾和弦）
    let leftHand: LeftHand
    let melodyCenter: Int
    let rhythms: [MelodyWriter.Rhythm]
    let plan: [(rhythm: Int, contour: Int)]
    let seed: UInt64

    func render(seconds: Double) -> Stereo {
        var rng = RNG(seed: seed)
        var mix = Stereo(seconds: seconds)
        var notes: [Note] = []
        let bodyBars = chords.count - 1

        // 左手
        for bar in 0..<bodyBars {
            let chord = chords[bar]
            var root = chord.root
            while root > 47 { root -= 12 }
            while root < 36 { root += 12 }
            let third = chord.pitches[1] - chord.pitches[0]
            let voicing = [root, root + 7, root + 12, root + 12 + third, root + 19]
            let start = Double(bar) * beatsPerBar
            switch leftHand {
            case .arpeggio:
                for (k, index) in [0, 1, 2, 3, 4, 3, 2, 1].enumerated() {
                    notes.append(Note(beat: start + Double(k) * 0.5, length: 1.6, pitch: voicing[index], velocity: k == 0 ? 0.55 : 0.42))
                }
            case .waltz:
                notes.append(Note(beat: start, length: 2.5, pitch: root, velocity: 0.55))
                for beat in [1.0, 2.0] {
                    for p in [root + 12, root + 12 + third, root + 19] {
                        notes.append(Note(beat: start + beat, length: 0.8, pitch: p, velocity: 0.36))
                    }
                }
            case .walking:
                notes.append(Note(beat: start, length: 1, pitch: root, velocity: 0.55))
                notes.append(Note(beat: start + 2, length: 1, pitch: root + 7 - 12 < 33 ? root + 7 : root + 7 - 12, velocity: 0.5))
                for beat in [1.0, 3.0] {
                    for p in [root + 12, root + 12 + third, root + 19] {
                        notes.append(Note(beat: start + beat, length: 0.6, pitch: p, velocity: 0.34))
                    }
                }
            }
        }

        // 右手旋律
        var writer = MelodyWriter(scale: scale, center: melodyCenter, beatsPerBar: beatsPerBar, rng: RNG(seed: seed &+ 7))
        notes += writer.write(chords: Array(chords.prefix(bodyBars)), rhythms: rhythms, plan: plan)

        // 结尾和弦：低音、和弦、旋律的主音
        let endBeat = Double(bodyBars) * beatsPerBar
        let end = chords[bodyBars]
        var low = end.root
        while low > 47 { low -= 12 }
        for p in [low - 12, low, low + 7] + end.pitches.map({ $0 + 12 }) {
            notes.append(Note(beat: endBeat, length: beatsPerBar * 1.5, pitch: p, velocity: 0.5))
        }
        notes.append(Note(beat: endBeat, length: beatsPerBar * 1.5, pitch: nearestTonic(to: melodyCenter), velocity: 0.62))

        for note in notes {
            let jitter = Int(rng.bipolar() * Float(sampleRate) * 0.006)
            let gate = tempo.seconds(note.length) * 1.05
            let sound = Piano.note(note.pitch, gate: gate, velocity: note.velocity * (0.94 + rng.float() * 0.08), rng: &rng)
            let pan = max(-0.6, min(0.6, Float(note.pitch - 60) / 40))
            mix.add(sound, at: max(0, tempo.sample(note.beat) + jitter), gain: 1, pan: pan)
        }
        let wet = reverb(mix, roomSize: 0.84, damping: 0.35)
        mix.mix(wet, gain: 0.32)
        mix.finish(fadeOut: 3.5)
        return mix
    }

    private func nearestTonic(to pitch: Int) -> Int {
        var p = scale.tonic
        while p + 12 <= pitch + 6 { p += 12 }
        return p
    }
}

enum PianoAlbum {
    /// 《窗边的雨》：C 大调，每分钟 80 拍，左手分解和弦。
    static let rain = PianoPiece(
        tempo: Tempo(bpm: 80), beatsPerBar: 4, scale: .major(0),
        chords: [triad("C", 48), triad("Am", 45, minor: true), triad("F", 41), triad("G", 43),
                 triad("C", 48), triad("Am", 45, minor: true), triad("Dm", 50, minor: true), triad("G", 43), triad("C", 48)],
        leftHand: .arpeggio, melodyCenter: 74,
        rhythms: [[(0, 1.5), (1.5, 0.5), (2, 1), (3, 1), (4, 1), (5, 1), (6, 2)],
                  [(0, 1), (1, 0.5), (1.5, 0.5), (2, 1.5), (3.5, 0.5), (4, 1.5), (5.5, 0.5), (6, 2)]],
        plan: [(0, 0), (0, 0), (1, 1), (0, 0)], seed: 101)

    /// 《旧书页》：a 小调圆舞曲，每分钟 88 拍。
    static let pages = PianoPiece(
        tempo: Tempo(bpm: 88), beatsPerBar: 3, scale: .minor(9),
        chords: [triad("Am", 45, minor: true), triad("F", 41), triad("C", 48), triad("G", 43),
                 triad("Am", 45, minor: true), triad("Dm", 50, minor: true), triad("E", 40), triad("Am", 45, minor: true),
                 triad("F", 41), triad("C", 48), triad("Dm", 50, minor: true), triad("E", 40), triad("Am", 45, minor: true)],
        leftHand: .waltz, melodyCenter: 76,
        rhythms: [[(0, 2), (2, 1), (3, 1.5), (4.5, 0.5), (5, 1)],
                  [(0, 1), (1, 1), (2, 1), (3, 3)],
                  [(0, 1.5), (1.5, 0.5), (2, 1), (3, 1), (4, 2)]],
        plan: [(0, 0), (1, 1), (0, 0), (2, 2), (0, 0), (2, 3)], seed: 202)

    /// 《傍晚散步》：F 大调，每分钟 100 拍，左手低音与和弦交替。
    static let walk = PianoPiece(
        tempo: Tempo(bpm: 100), beatsPerBar: 4, scale: .major(5),
        chords: [triad("F", 41), triad("Dm", 50, minor: true), triad("Bb", 46), triad("C", 48),
                 triad("F", 41), triad("Dm", 50, minor: true), triad("Gm", 43, minor: true), triad("C", 48),
                 triad("Bb", 46), triad("C", 48), triad("F", 41)],
        leftHand: .walking, melodyCenter: 77,
        rhythms: [[(0, 0.5), (0.5, 0.5), (1, 1), (2.5, 0.5), (3, 1), (4, 1.5), (5.5, 0.5), (6, 1), (7, 1)],
                  [(0, 1.5), (1.5, 1.5), (3, 1), (4, 0.5), (4.5, 0.5), (5, 1), (6, 2)]],
        plan: [(0, 0), (1, 1), (0, 0), (1, 2), (0, 0)], seed: 303)
}
