import Foundation

/// 木吉他民谣：扫弦或分解指弹的木吉他、口哨般的旋律、轻轻的沙锤。
struct FolkPiece {
    enum Style {
        /// 扫弦：每小节的 (拍位, 下扫?) 列表。
        case strum([(Double, Bool)])
        /// 指弹：每半拍拨一根弦，按给定的弦序。
        case fingerpick([Int])
    }

    let tempo: Tempo
    let beatsPerBar: Double
    let scale: Scale
    /// 每小节一个和弦：名称（用于取吉他按法）与音高（用于旋律找和弦音）。
    let chords: [Chord]
    let style: Style
    let melodyCenter: Int
    let rhythms: [MelodyWriter.Rhythm]
    let plan: [(rhythm: Int, contour: Int)]
    /// 旋律从第几小节开始（前面是吉他前奏）。
    let melodyStartBar: Int
    let shakerFromBar: Int?
    let seed: UInt64

    /// 常见的吉他和弦按法（标准调弦，从低音弦到高音弦）。
    static let shapes: [String: [Int]] = [
        "G": [43, 47, 50, 55, 59, 67], "D": [50, 57, 62, 66], "Em": [40, 47, 52, 55, 59, 64],
        "C": [48, 52, 55, 60, 64], "Am": [45, 52, 57, 60, 64], "A": [45, 52, 57, 61, 64],
        "Bm": [47, 54, 59, 62, 66], "F": [41, 48, 53, 57, 60, 65], "Dm": [50, 57, 62, 65],
        "E": [40, 47, 52, 56, 59, 64],
    ]

    func render(seconds: Double) -> Stereo {
        var rng = RNG(seed: seed)
        var guitar = Stereo(seconds: seconds)
        let bodyBars = chords.count - 1

        // 吉他
        for bar in 0..<bodyBars {
            let shape = Self.shapes[chords[bar].name] ?? chords[bar].pitches
            let barStart = Double(bar) * beatsPerBar
            switch style {
            case .strum(let pattern):
                for (k, (beat, down)) in pattern.enumerated() {
                    let next = k + 1 < pattern.count ? pattern[k + 1].0 : beatsPerBar + pattern[0].0
                    let ring = tempo.seconds(next - beat) + 0.05
                    let jitter = Int(rng.bipolar() * Float(sampleRate) * 0.008)
                    let accent: Float = beat.truncatingRemainder(dividingBy: 2) == 0 ? 0.95 : 0.75
                    Guitar.strum(shape, down: down, velocity: accent, ring: ring, into: &guitar,
                                 at: max(0, tempo.sample(barStart + beat) + jitter), rng: &rng)
                }
            case .fingerpick(let order):
                let steps = Int(beatsPerBar * 2)
                for k in 0..<steps {
                    let string = order[k % order.count]
                    let pitch = shape[min(string, shape.count - 1)]
                    let isBass = k == 0 || (k == steps / 2 && beatsPerBar >= 4)
                    let note = isBass ? shape[0] : pitch
                    let sound = Guitar.pluck(note, ring: isBass ? tempo.seconds(beatsPerBar) : 1.4,
                                             velocity: isBass ? 0.8 : 0.6 + rng.float() * 0.1, rng: &rng)
                    let pan = isBass ? -0.25 : Float(string) / 6 * 0.6 - 0.1
                    let jitter = Int(rng.bipolar() * Float(sampleRate) * 0.006)
                    guitar.add(sound, at: max(0, tempo.sample(barStart + Double(k) * 0.5) + jitter), gain: 0.6, pan: pan)
                }
            }
        }
        // 结尾：慢慢地下扫一次主和弦，让它响完
        let endShape = Self.shapes[chords[bodyBars].name] ?? chords[bodyBars].pitches
        Guitar.strum(endShape, down: true, velocity: 0.8, ring: 4, into: &guitar,
                     at: tempo.sample(Double(bodyBars) * beatsPerBar), rng: &rng)

        var mix = guitar
        // 旋律
        var writer = MelodyWriter(scale: scale, center: melodyCenter, beatsPerBar: beatsPerBar, rng: RNG(seed: seed &+ 11))
        let melody = writer.write(chords: Array(chords.prefix(bodyBars)), rhythms: rhythms, plan: plan, startBar: melodyStartBar)
        for note in melody {
            let sound = Lead.whistle(note.pitch, gate: tempo.seconds(note.length) * 0.92, velocity: note.velocity)
            mix.add(sound, at: tempo.sample(note.beat), gain: 1, pan: 0.15)
        }
        // 沙锤：每半拍一下，反拍稍重
        if let from = shakerFromBar {
            for k in Int(Double(from) * beatsPerBar * 2) ..< Int(Double(bodyBars) * beatsPerBar * 2) {
                let sound = Drums.shaker(rng: &rng)
                mix.add(sound, at: tempo.sample(Double(k) * 0.5), gain: k % 2 == 1 ? 0.12 : 0.07, pan: 0.45)
            }
        }
        let wet = reverb(mix, roomSize: 0.78, damping: 0.4)
        mix.mix(wet, gain: 0.22)
        mix.finish(fadeOut: 3.5)
        return mix
    }
}

enum FolkAlbum {
    /// 《南方小站》：G 大调扫弦，每分钟 100 拍。
    static let station = FolkPiece(
        tempo: Tempo(bpm: 100), beatsPerBar: 4, scale: .major(7),
        chords: ["G", "D", "Em", "C", "G", "D", "Em", "C", "C", "D", "G"].map(folkChord),
        style: .strum([(0, true), (1, true), (1.5, false), (2.5, false), (3, true), (3.5, false)]),
        melodyCenter: 74,
        rhythms: [[(0, 1), (1, 1), (2, 1.5), (3.5, 0.5), (4, 2), (6, 2)],
                  [(0, 0.5), (0.5, 0.5), (1, 1), (2, 1), (3, 1), (4, 1.5), (5.5, 0.5), (6, 2)]],
        plan: [(0, 0), (1, 1), (0, 0), (1, 2)], melodyStartBar: 2, shakerFromBar: 2, seed: 401)

    /// 《风吹过的路》：D 大调指弹，每分钟 96 拍（配有歌词）。
    static let road = FolkPiece(
        tempo: Tempo(bpm: 96), beatsPerBar: 4, scale: .major(2),
        chords: ["D", "A", "Bm", "G", "D", "A", "G", "A", "D", "Bm", "D"].map(folkChord),
        style: .fingerpick([0, 3, 2, 4, 3, 2, 4, 2]),
        melodyCenter: 74,
        rhythms: [[(0, 1.5), (1.5, 0.5), (2, 1), (3, 1), (4, 3)],
                  [(0, 1), (1, 1), (2, 1), (3, 1), (4, 1.5), (5.5, 0.5), (6, 2)]],
        plan: [(0, 0), (1, 1), (0, 0), (1, 2)], melodyStartBar: 2, shakerFromBar: nil, seed: 502)

    /// 《篝火边》：C 大调三拍子扫弦，每分钟 120 拍。
    static let campfire = FolkPiece(
        tempo: Tempo(bpm: 120), beatsPerBar: 3, scale: .major(0),
        chords: ["C", "Am", "F", "G", "C", "Am", "F", "G", "Am", "F", "C", "G", "C", "Am", "F", "G", "C"].map(folkChord),
        style: .strum([(0, true), (1, true), (1.5, false), (2, true), (2.5, false)]),
        melodyCenter: 72,
        rhythms: [[(0, 2), (2, 1), (3, 1.5), (4.5, 0.5), (5, 1)],
                  [(0, 1), (1, 1), (2, 1), (3, 3)]],
        plan: [(0, 0), (1, 1), (0, 0), (1, 2), (0, 0), (1, 1), (0, 3)], melodyStartBar: 2, shakerFromBar: 4, seed: 603)

    static func folkChord(_ name: String) -> Chord {
        let roots: [String: Int] = ["C": 48, "D": 50, "E": 52, "F": 53, "G": 55, "A": 57, "B": 59]
        let minor = name.hasSuffix("m")
        let base = roots[String(name.prefix(1))] ?? 48
        return triad(name, base, minor: minor)
    }
}
