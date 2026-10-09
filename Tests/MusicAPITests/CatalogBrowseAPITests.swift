import Foundation
import Testing
@testable import MusicAPI
import ProviderKit

/// 逐层浏览接口结构的解码测试：定稿里的例子、不认识的开放取值、可选字段缺失。
struct CatalogBrowseAPITests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func 功能名catalogBrowse() {
        #expect(API.ServerFeature(rawValue: "catalogBrowse") == .catalogBrowse)
        let info = API.ServerInfo(serverVersion: "x", protocolVersion: API.protocolVersion, features: [.catalog, .catalogBrowse])
        #expect(info.knownFeatures.contains(.catalogBrowse))
        #expect(API.protocolVersion == 2)
    }

    @Test func 路径都在browse下() {
        let paths = [API.Path.browseDomains, API.Path.browsePage, API.Path.browseList, API.Path.browseArticle,
                     API.Path.browseSearch, API.Path.browseSearchList, API.Path.browseTracks, API.Path.browseForLibrary]
        #expect(paths.allSatisfy { $0.hasPrefix("/v1/catalog/browse/") })
        #expect(Set(paths).count == paths.count)
    }

    @Test func 定稿里的作品页例子() throws {
        let json = """
        {
          "ref": {"kind": "work", "id": "1070456"},
          "header": {"title": "Symphony No. 5 in C minor, Op. 67", "localizedTitle": "C小调第五交响曲",
                     "line": "作品67，贝多芬，1808", "kindTitle": "作品", "owned": true},
          "summary": {"text": "C小调第五交响曲是贝多芬创作的交响曲。", "language": "zh-Hans",
                      "attribution": {"source": "维基百科", "line": "来自维基百科《第5号交响曲 (贝多芬)》，知识共享 署名-相同方式共享 4.0",
                                      "url": "https://zh.wikipedia.org/wiki/x", "license": "CC BY-SA 4.0"}},
          "hasArticle": true,
          "play": {"style": "play", "trackCount": 4},
          "links": [{"title": "作曲家", "item": {"ref": {"kind": "artist", "id": "1021"}, "title": "Ludwig van Beethoven", "localizedTitle": "贝多芬"}}],
          "tabs": [{"id": "overview", "title": "概览", "kind": "overview", "isDefault": true},
                   {"id": "performances", "title": "录音", "kind": "list", "isDefault": false,
                    "list": {"section": "performances", "title": "全部录音", "display": "list",
                             "sorts": [{"id": "popularity", "title": "热度", "defaultOrder": "desc"}], "defaultSort": "popularity",
                             "views": [{"id": "performances", "title": "按录音"}, {"id": "albums", "title": "按专辑"}],
                             "filters": [{"id": "completeOnly", "title": "只看完整录音", "type": "toggle", "defaultOn": true}],
                             "textFilter": true}}],
          "sections": [
            {"id": "parts", "title": "乐章", "countText": "4个", "display": "tracks", "items": []},
            {"id": "libraryPerformances", "title": "资料库里的录音", "countText": "2个", "display": "list", "tab": "performances",
             "items": [{"ref": {"kind": "performance", "id": "3456789"}, "title": "Karajan, Berliner Philharmoniker",
                        "subtitle": "卡拉扬，柏林爱乐乐团，1962", "owned": true, "year": 1962,
                        "target": {"ref": {"kind": "release", "id": "22334455"}, "focusGroup": "w1070456"}}]}
          ],
          "dataVersion": "b2026-10-06.w2026-10-01"
        }
        """
        let page = try decode(API.BrowsePage.self, json)
        #expect(page.ref == API.BrowseRef(kind: .work, id: "1070456"))
        #expect(page.header.owned == true)
        #expect(page.summary?.attribution.license == "CC BY-SA 4.0")
        #expect(page.tabs[1].list?.filters.first?.defaultOn == true)
        #expect(page.sections[0].display == .tracks)
        #expect(page.sections[1].items[0].target?.focusGroup == "w1070456")
        #expect(page.libraryCopies == nil)
        // 编码再解码不变。
        let again = try JSONDecoder().decode(API.BrowsePage.self, from: JSONEncoder().encode(page))
        #expect(again == page)
    }

    @Test func 不认识的类型值照样解码() throws {
        let json = """
        {"ref": {"kind": "podcastSeries", "id": "abc"}, "title": "未来的对象", "target": {"ref": {"kind": "playlist", "id": "9"}}}
        """
        let item = try decode(API.BrowseItem.self, json)
        #expect(item.ref.kind.rawValue == "podcastSeries")
        #expect(item.ref.kind != .artist)
        #expect(item.target?.ref.kind == API.BrowseKind(rawValue: "playlist"))

        let section = try decode(API.BrowseSection.self, """
        {"id": "s", "title": "段", "display": "carousel3d", "items": []}
        """)
        #expect(section.display.rawValue == "carousel3d")

        let filter = try decode(API.BrowseFilter.self, """
        {"id": "range", "title": "年份范围", "type": "slider"}
        """)
        #expect(filter.type == "slider")
        #expect(filter.options == nil)

        let tab = try decode(API.BrowseTab.self, """
        {"id": "x", "title": "时间线", "kind": "timeline", "isDefault": false}
        """)
        #expect(tab.kind == "timeline")

        // 功能列表里有不认识的名字时忽略。
        let info = try decode(API.ServerInfo.self, """
        {"serverVersion": "1", "protocolVersion": 2, "features": ["catalogBrowse", "somethingNew"]}
        """)
        #expect(info.knownFeatures == [.catalogBrowse])
    }

    @Test func 可选字段缺失() throws {
        let page = try decode(API.BrowsePage.self, """
        {"ref": {"kind": "artist", "id": "1021"}, "header": {"title": "Ludwig van Beethoven"},
         "hasArticle": false, "links": [], "tabs": [], "sections": [], "dataVersion": "v"}
        """)
        #expect(page.summary == nil)
        #expect(page.play == nil)
        #expect(page.header.localizedTitle == nil)
        #expect(page.header.owned == nil)
        #expect(page.header.artworkURL == nil)

        let item = try decode(API.BrowseItem.self, """
        {"ref": {"kind": "work", "id": "1"}, "title": "Allegro con brio"}
        """)
        #expect(item.subtitle == nil && item.owned == nil && item.target == nil && item.libraryTrack == nil)
        #expect(item.groupPath == nil && item.matched == nil && item.durationMs == nil)

        let list = try decode(API.BrowseListPage.self, """
        {"items": [], "dataVersion": "v"}
        """)
        #expect(list.nextCursor == nil && list.total == nil && list.sort == nil)

        let article = try decode(API.BrowseArticle.self, """
        {"ref": {"kind": "label", "id": "743"}, "title": "Deutsche Grammophon", "sections": [], "facts": [], "dataVersion": "v"}
        """)
        #expect(article.attribution == nil && article.language == nil)

        let search = try decode(API.BrowseSearchResult.self, """
        {"query": "贝多芬 op 67", "top": [], "groups": [{"id": "work", "title": "作品", "items": [], "hasMore": false}], "dataVersion": "v"}
        """)
        #expect(search.interpretation == nil)
        #expect(search.groups.first?.total == nil)

        let links = try decode(API.BrowseLibraryLinks.self, """
        {"status": "pending", "links": [], "dataVersion": "v"}
        """)
        #expect(links.release == nil)

        let domains = try decode(API.BrowseDomains.self, """
        {"domains": [{"id": "classical", "title": "古典音乐", "libraryLists": []}], "dataVersion": "v"}
        """)
        #expect(domains.domains.first?.symbol == nil)
    }

    @Test func 曲目与专辑沿用现有结构() throws {
        let track = PlatformTrack(ref: PlatformResourceRef(platform: PlatformID("1"), kind: .track, platformID: "t1"),
                                  metadata: TrackMetadata(title: "I. Allegro con brio", artists: ["Karajan"]))
        let album = PlatformAlbum(ref: PlatformResourceRef(platform: PlatformID("1"), kind: .album, platformID: "a1"),
                                  title: "Beethoven: Symphonies 5 & 7", artists: ["Karajan"])
        let page = API.BrowsePage(ref: .init(kind: .release, id: "22334455"), header: .init(title: "x"),
                                  sections: [.init(id: "tracks", title: "曲目", display: .tracks,
                                                   items: [.init(ref: .init(kind: .track, id: "5"), title: "Allegro", libraryTrack: track)])],
                                  libraryCopies: [.init(album: album, status: "recognized", reasons: ["唱片编号一致"],
                                                        matchedTracks: 4, releaseTracks: 4)],
                                  dataVersion: "v")
        let back = try JSONDecoder().decode(API.BrowsePage.self, from: JSONEncoder().encode(page))
        #expect(back.libraryCopies?.first?.album.ref.platformID == "a1")
        #expect(back.sections[0].items[0].libraryTrack?.ref.platform.rawValue == "1")
        let tracks = try JSONDecoder().decode(API.BrowseTracks.self,
                                              from: JSONEncoder().encode(API.BrowseTracks(tracks: [track], dataVersion: "v")))
        #expect(tracks.tracks.count == 1)
    }
}
