import Foundation

// 生成示例音乐：3 张专辑、每张 3 首、每首 30 秒，全部由程序合成（本项目原创，CC0）。
// 用法：生成示例音乐 <输出文件夹>（文件夹名必须是“示例音乐”；已有的会被整个换成新生成的）。
// 同样的程序每次生成的音乐相同（随机数有固定种子）；FLAC 与 M4A 文件的编码细节可能随系统版本略有不同。

struct Song {
    let number: Int
    let title: String
    let format: Format
    let render: @Sendable () -> Stereo
    let lyrics: String?
    enum Format { case flac, alac }
}

struct Album {
    let title: String
    let artist: String
    let year: Int
    let genre: String
    let cover: Cover.Style
    let songs: [Song]
    var folderName: String { "\(artist) - \(title)" }
}

let seconds = 30.0
let comment = "轻量音乐服务器示例音乐：本项目原创，程序合成，以 CC0 发布"

let roadLyrics = """
[ti:风吹过的路]
[ar:麦田旅人]
[al:风吹过的路]
[00:00.00]风吹过的路
[00:05.00]清早的风 吹过田埂
[00:07.50]把露水 轻轻摇醒
[00:10.00]背包里装着 半块月亮
[00:12.50]和一封 没寄出的信
[00:15.00]走吧 走过那片麦浪
[00:17.50]脚印会替我 记得方向
[00:20.00]风吹过的路 长又长
[00:22.50]我在路上 慢慢地唱
[00:26.00]

"""

let pulseLyrics = """
[ti:城市脉搏]
[ar:霓虹回路]
[al:夜行列车]
[00:00.00]城市脉搏
[00:04.07]零点的街灯 一盏接一盏
[00:06.10]车流像河 不肯靠岸
[00:08.14]耳机里的鼓点 和心跳同步
[00:10.17]霓虹替我 说晚安
[00:12.20]跟着节拍 穿过人海
[00:14.24]把疲惫 留在站台
[00:16.27]这座城市 从不睡去
[00:18.31]它的脉搏 敲着我的未来
[00:20.34]

"""

let albums: [Album] = [
    Album(title: "晨光小品集", artist: "白石小屋", year: 2024, genre: "钢琴", cover: .morning, songs: [
        Song(number: 1, title: "窗边的雨", format: .flac, render: { PianoAlbum.rain.render(seconds: seconds) }, lyrics: nil),
        Song(number: 2, title: "旧书页", format: .flac, render: { PianoAlbum.pages.render(seconds: seconds) }, lyrics: nil),
        Song(number: 3, title: "傍晚散步", format: .flac, render: { PianoAlbum.walk.render(seconds: seconds) }, lyrics: nil),
    ]),
    Album(title: "夜行列车", artist: "霓虹回路", year: 2025, genre: "电子", cover: .night, songs: [
        Song(number: 1, title: "零点出发", format: .alac, render: { ElectronicAlbum.departure.render(seconds: seconds) }, lyrics: nil),
        Song(number: 2, title: "城市脉搏", format: .alac, render: { ElectronicAlbum.pulse.render(seconds: seconds) }, lyrics: pulseLyrics),
        Song(number: 3, title: "霓虹回声", format: .alac, render: { ElectronicAlbum.echoes.render(seconds: seconds) }, lyrics: nil),
    ]),
    Album(title: "风吹过的路", artist: "麦田旅人", year: 2026, genre: "民谣", cover: .fields, songs: [
        Song(number: 1, title: "南方小站", format: .flac, render: { FolkAlbum.station.render(seconds: seconds) }, lyrics: nil),
        Song(number: 2, title: "风吹过的路", format: .alac, render: { FolkAlbum.road.render(seconds: seconds) }, lyrics: roadLyrics),
        Song(number: 3, title: "篝火边", format: .flac, render: { FolkAlbum.campfire.render(seconds: seconds) }, lyrics: nil),
    ]),
]

func generate(into output: URL) async throws {
    let fm = FileManager.default
    guard output.lastPathComponent == "示例音乐" else {
        throw WriterError.failed("输出文件夹名必须是“示例音乐”，现在是 \(output.lastPathComponent)")
    }
    let staging = output.deletingLastPathComponent().appending(path: ".示例音乐-生成中", directoryHint: .isDirectory)
    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    for album in albums {
        let folder = staging.appending(path: album.folderName, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let cover = try Cover.draw(album.cover, title: album.title, artist: album.artist)
        try cover.write(to: folder.appending(path: "cover.jpg"))
        print("封面：\(album.folderName)/cover.jpg，\(cover.count / 1024) KB")

        try await withThrowingTaskGroup(of: String.self) { group in
            for song in album.songs {
                group.addTask {
                    let begin = Date()
                    let audio = song.render()
                    var rng = RNG(seed: UInt64(song.number) &* 7919)
                    let pcm = audio.int16Interleaved(rng: &rng)
                    let base = String(format: "%02d %@", song.number, song.title)
                    let tags = TrackTags(title: song.title, artist: album.artist, album: album.title, trackNumber: song.number,
                                         trackTotal: album.songs.count, year: album.year, genre: album.genre, comment: comment)
                    let file: URL
                    switch song.format {
                    case .flac:
                        file = folder.appending(path: base + ".flac")
                        try FLACWriter.write(pcm, to: file, tags: tags, cover: cover, coverSize: Cover.size)
                    case .alac:
                        file = folder.appending(path: base + ".m4a")
                        try await ALACWriter.write(pcm, to: file, tags: tags, cover: cover)
                    }
                    if let lyrics = song.lyrics {
                        try Data(lyrics.utf8).write(to: folder.appending(path: base + ".lrc"))
                    }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return "\(album.folderName)/\(file.lastPathComponent)：\(size / 1024) KB，合成用时 \(String(format: "%.1f", Date().timeIntervalSince(begin))) 秒"
                }
            }
            for try await line in group { print(line) }
        }
    }
    // 整个换上
    if fm.fileExists(atPath: output.path(percentEncoded: false)) { try fm.removeItem(at: output) }
    try fm.moveItem(at: staging, to: output)
    print("完成：\(output.path(percentEncoded: false))")
}

guard CommandLine.arguments.count == 2 else {
    print("用法：生成示例音乐 <输出文件夹（名为“示例音乐”）>")
    exit(2)
}
do {
    try await generate(into: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
} catch {
    print("出错：\(error)")
    exit(1)
}
