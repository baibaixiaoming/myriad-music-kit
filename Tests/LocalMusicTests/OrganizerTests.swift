import Testing
@testable import LocalMusic

private typealias Track = LocalMusicLibrary.IndexedTrack

private func track(_ path: String, title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                   number: Int? = nil, disc: Int? = nil, year: Int? = nil, ms: Int = 200_000,
                   rate: Int = 44100, bits: Int = 16, codec: String = "flac", lossless: Bool = true, mb: String? = nil) -> Track {
    var raw: [String: [String]] = [:]
    if let title { raw["TITLE"] = [title] }
    if let artist { raw["ARTIST"] = [artist] }
    if let album { raw["ALBUM"] = [album] }
    if let albumArtist { raw["ALBUMARTIST"] = [albumArtist] }
    if let number { raw["TRACKNUMBER"] = ["\(number)"] }
    if let disc { raw["DISCNUMBER"] = ["\(disc)"] }
    if let year { raw["DATE"] = ["\(year)"] }
    if let mb { raw["MUSICBRAINZ_ALBUMID"] = [mb] }
    let base = (path as NSString).lastPathComponent
    var t = Track.make(path: path, folderID: "f", tags: TagValues(raw), fallbackTitle: (base as NSString).deletingPathExtension, durationMS: ms)
    t.sampleRate = rate; t.bitDepth = bits; t.codec = codec; t.lossless = lossless
    return t
}

import Foundation

struct OrganizerTests {
    @Test func multiDiscFoldersBecomeOneAlbum() {
        let tracks = [
            track("/m/Pink Floyd - The Wall/CD1/01.flac", title: "In the Flesh?", artist: "Pink Floyd", album: "The Wall (Disc 1)", number: 1),
            track("/m/Pink Floyd - The Wall/CD1/02.flac", title: "The Thin Ice", artist: "Pink Floyd", album: "The Wall (Disc 1)", number: 2),
            track("/m/Pink Floyd - The Wall/CD2/01.flac", title: "Hey You", artist: "Pink Floyd", album: "The Wall (Disc 2)", number: 1),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(c.albums.count == 1)
        let a = c.albums[0]
        #expect(a.title == "The Wall")
        #expect(a.discCount == 2)
        #expect(a.songs.map(\.title) == ["In the Flesh?", "The Thin Ice", "Hey You"])
        #expect(a.songs.map(\.disc) == [1, 1, 2])
    }

    @Test func classicalBoxStaysTogether() {
        var tracks: [Track] = []
        for d in 1...3 {
            for n in 1...2 {
                tracks.append(track("/m/Beethoven Complete Symphonies/Disc \(d)/\(n).flac", title: "Symphony \(d * 2 + n - 2): Mvt \(n)",
                                    artist: "Berliner Philharmoniker; Herbert von Karajan", album: "Beethoven: Symphonies No.\(d)",
                                    albumArtist: "Herbert von Karajan", number: n))
            }
        }
        let c = LibraryCatalog.build(tracks)
        #expect(c.albums.count == 1)
        #expect(c.albums[0].discCount == 3)
        #expect(c.albums[0].songs.count == 6)
        #expect(c.albums[0].artist == "Herbert von Karajan")
    }

    @Test func duplicatesCollapseKeepingBest() {
        let tracks = [
            track("/m/a/01.mp3", title: "Song", artist: "X", album: "A", number: 1, ms: 200_000, codec: "mp3", lossless: false),
            track("/m/b/01.flac", title: "Song", artist: "X", album: "A", number: 1, ms: 201_500),
            track("/m/b/02.flac", title: "Other", artist: "X", album: "A", number: 2),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(c.albums.count == 1)
        #expect(c.albums[0].songs.count == 2)
        #expect(c.albums[0].songs[0].track.codec == "flac")
        #expect(c.albums[0].songs[0].alternates.count == 1)
        #expect(c.songs.count == 2)
    }

    @Test func hiResAndDSDAreSeparateVersions() {
        let tracks = [
            track("/m/cd/01.flac", title: "One", artist: "X", album: "A", number: 1),
            track("/m/cd/02.flac", title: "Two", artist: "X", album: "A", number: 2),
            track("/m/hr/01.flac", title: "One", artist: "X", album: "A", number: 1, rate: 96000, bits: 24),
            track("/m/hr/02.flac", title: "Two", artist: "X", album: "A", number: 2, rate: 96000, bits: 24),
            track("/m/dsd/01.dsf", title: "One", artist: "X", album: "A", number: 1, rate: 2_822_400, bits: 1, codec: "dsd"),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(Set(c.albums.map(\.displayTitle)) == ["A · 16bit/44.1kHz", "A · 24bit/96kHz", "A · DSD64"])
        #expect(c.songs.count == 1)   // 歌曲列表只取最好的版本（DSD）
        #expect(c.songs[0].track.codec == "dsd")
    }

    @Test func sameNameDifferentAlbumsNotMerged() {
        let tracks = [
            track("/m/1/01.flac", title: "Intro", artist: "Weezer", album: "Weezer", number: 1, year: 1994),
            track("/m/2/01.flac", title: "California", artist: "Weezer", album: "Weezer", number: 1, year: 2001),
        ]
        #expect(LibraryCatalog.build(tracks).albums.count == 2)
    }

    @Test func untaggedFilesUseFolderAndFileName() {
        let tracks = [
            track("/m/周杰伦 - 范特西/01. 爱在西元前.mp3", codec: "mp3", lossless: false),
            track("/m/周杰伦 - 范特西/02 - 简单爱.mp3", codec: "mp3", lossless: false),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(c.albums.count == 1)
        #expect(c.albums[0].title == "范特西")
        #expect(c.albums[0].artist == "周杰伦")
        #expect(c.albums[0].songs.map(\.title) == ["爱在西元前", "简单爱"])
        #expect(c.albums[0].songs.map(\.number) == [1, 2])
    }

    @Test func artistsMergeAcrossWritingForms() {
        let tracks = [
            track("/m/1/01.flac", title: "a", artist: "周杰倫", album: "A", number: 1),
            track("/m/2/01.flac", title: "b", artist: "周杰伦", album: "B", number: 1),
            track("/m/2/02.flac", title: "c", artist: "周杰伦", album: "B", number: 2),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(c.artists.count == 1)
        #expect(c.artists[0].name == "周杰伦")
        #expect(c.artists[0].albumIDs.count == 2)
    }

    @Test func compilationGoesToVariousArtists() {
        let tracks = [
            track("/m/hits/01.flac", title: "a", artist: "A", album: "Hits", number: 1),
            track("/m/hits/02.flac", title: "b", artist: "B", album: "Hits", number: 2),
            track("/m/hits/03.flac", title: "c", artist: "C", album: "Hits", number: 3),
        ]
        let c = LibraryCatalog.build(tracks)
        #expect(c.albums.count == 1)
        #expect(c.albums[0].artist == "群星")
    }
}

struct ClassicalTagTests {
    @Test func performerCredits() {
        let t = TagValues([
            "COMPOSER": ["Ludwig van Beethoven"],
            "CONDUCTOR": ["Herbert von Karajan"],
            "ORCHESTRA": ["Berliner Philharmoniker"],
            "PERFORMER": ["Anne-Sophie Mutter (violin)", "Mark Zeltser (piano); Yo-Yo Ma (cello)"],
            "LABEL": ["Deutsche Grammophon"],
            "CATALOGNUMBER": ["415 276-2"],
            "GENRE": ["Classical"],
            "WORK": ["Triple Concerto in C major, Op. 56"],
            "MOVEMENTNAME": ["Allegro"],
        ])
        #expect(t.composers == ["Ludwig van Beethoven"])
        #expect(t.conductors == ["Herbert von Karajan"])
        #expect(t.ensembles == ["Berliner Philharmoniker"])
        #expect(t.performers == [.init(name: "Anne-Sophie Mutter", role: "violin"), .init(name: "Mark Zeltser", role: "piano"),
                                 .init(name: "Yo-Yo Ma", role: "cello")])
        #expect(t.label == "Deutsche Grammophon")
        #expect(t.catalogNumber == "415 276-2")
        let track = LocalMusicLibrary.IndexedTrack.make(path: "/m/a.flac", folderID: "f", tags: t, fallbackTitle: "a", durationMS: 1000)
        #expect(track.performers?.map(\.role) == ["violin", "piano", "cello"])
        #expect(track.work == "Triple Concerto in C major, Op. 56")
    }
}
