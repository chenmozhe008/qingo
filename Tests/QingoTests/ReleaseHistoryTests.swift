import Foundation
import Testing
@testable import Qingo

@Suite
struct ReleaseHistoryTests {
    @Test
    func publishedAndDevelopmentSameVersionRemainDistinct() throws {
        let json = """
        [{"tag_name":"v1.24.0","draft":false,"prerelease":false,"html_url":"https://github.com/example/releases/v1.24.0","published_at":"2026-11-24T00:00:00Z","body":"## 更新内容\\n\\n- 正式版说明"}, {"tag_name":"win-v1.0","draft":false,"prerelease":true}]
        """
        let online = try #require(ReleaseHistory.online(Data(json.utf8)))
        let local = ReleaseHistory.local("## 1.24.0 · 2026-11-24（开发版）\n- 本机改动", includeDevelopment: true)
        let rows = ReleaseHistory.merge(local: local, online: online)
        #expect(rows.count == 2)
        #expect(rows[0].isDevelopment)
        #expect(rows[0].notes == ["本机改动"])
        #expect(rows[1].notes == ["正式版说明"])
        #expect(rows[1].page != nil)
    }

    @Test
    func offlineLocalHistoryAndPublishedMerge() throws {
        let local = ReleaseHistory.local("## 1.23.0 · 2026-11-22\n- 本地记录", includeDevelopment: false)
        #expect(ReleaseHistory.merge(local: local, online: []) == local)

        let published = HistoryEntry(
            version: "1.23.0",
            date: "2026-11-23",
            notes: ["线上说明"],
            page: URL(string: "https://github.com/example")!,
            isDevelopment: false
        )
        let merged = ReleaseHistory.merge(local: local, online: [published])
        #expect(merged.count == 1)
        #expect(merged[0].notes == ["线上说明"])
        #expect(merged[0].page != nil)
    }

    @Test
    func releaseWithoutOnlineNotesKeepsLocalNotes() {
        let local = ReleaseHistory.local("## 1.23.0 · 2026-11-22\n- 本地记录", includeDevelopment: false)
        let empty = HistoryEntry(version: "1.23.0", date: "2026-11-23", notes: [], page: nil, isDevelopment: false)
        #expect(ReleaseHistory.merge(local: local, online: [empty])[0].notes == ["本地记录"])
    }

    @Test
    func invalidResponseReturnsNil() {
        #expect(ReleaseHistory.online(Data("{}".utf8)) == nil)
    }

    @Test
    func developmentBuildFilteringKeepsPublishedOnlyWhenDisabled() {
        let text = """
        ## 1.24.0 · 2026-11-24（开发版）
        - 本机开发
        ## 1.23.0 · 2026-11-22
        - 正式功能
        """
        let dev = ReleaseHistory.local(text, includeDevelopment: true)
        #expect(dev.filter(\.isDevelopment).map(\.notes) == [["本机开发"]])
        let publishedOnly = ReleaseHistory.local(text, includeDevelopment: false)
        #expect(publishedOnly == Array(dev.dropFirst()))
        #expect(publishedOnly.map(\.id) == ["1.23.0-release"])
    }
}
