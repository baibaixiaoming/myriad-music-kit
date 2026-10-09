import Testing
@testable import ProviderKit

@Suite struct LRCParserTests {
    @Test func multipleStampsAndMetadata() {
        let r = LRCParser.parse("[ar:歌手]\n[00:10.5][00:30.25]副歌\n[00:20.123]主歌")
        #expect(r.isSynced)
        #expect(r.metadata["ar"] == "歌手")
        #expect(r.lines.map(\.text) == ["副歌", "主歌", "副歌"])
        #expect(r.lines.map(\.start) == [.milliseconds(10500), .milliseconds(20123), .milliseconds(30250)])
    }

    @Test func offsetShiftsLines() {
        let r = LRCParser.parse("[offset:500]\n[00:01.00]a")
        #expect(r.lines.first?.start == .milliseconds(500))
    }

    @Test func plainTextHasNoTiming() {
        let r = LRCParser.parse("\n第一行\n第二行\n")
        #expect(!r.isSynced)
        #expect(r.lines.map(\.text) == ["第一行", "第二行"])
        #expect(r.lines.allSatisfy { $0.start == nil })
    }
}
