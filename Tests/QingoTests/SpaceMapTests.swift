import Foundation
import Testing
@testable import Qingo

/// 「空间分布」：其他＝已用 − 各块 − 可直接清理，不会是负数；启动盘系统卷读得到。
struct SpaceMapTests {
    @Test func remainderIsWhatTheBlocksDoNotExplain() {
        let gb: Int64 = 1_000_000_000
        let map = SpaceMap(measuredAt: Date(), total: 500 * gb, available: 20 * gb, blocks: [
            .init(id: "apps", title: "应用程序", bytes: 100 * gb, note: "", section: .decide, action: .uninstall),
            .init(id: "system", title: "macOS 系统", bytes: 40 * gb, note: "", section: .fixed, action: nil)])
        #expect(map.used == 480 * gb)
        #expect(map.remainder(cleanable: 10 * gb) == 330 * gb)
        #expect(map.remainder(cleanable: 1000 * gb) == 0)
    }

    @Test func systemVolumesOfTheStartupDiskAreMeasured() {
        #expect(SpaceMapper.systemVolumesBytes() > 5_000_000_000)
    }

    @Test func measuringADemoHomeStaysInsideIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300_000).write(to: home.appending(path: "Documents/a.bin"))
        let map = SpaceMapper(home: home, devRoot: home.appending(path: "Coding"), chatBytes: 0).measure()
        #expect((map.blocks.first { $0.id == "documents" }?.bytes ?? 0) >= 300_000)
        #expect(map.blocks.first { $0.id == "dev" }?.bytes == 0)
    }
}

struct TreemapLayoutTests {
    @Test func rowsFillTheHeightExactlyAndSmallRowsStayReadable() {
        let gb: Int64 = 1_000_000_000
        // 本机「无法清理」那一区：其他 112 + 系统数据 56 / macOS 44 + 其他 App 26 / 开发环境 16
        let heights = TreemapLayout.rowHeights([168 * gb, 70 * gb, 16 * gb], total: 254 * gb, height: 400)
        #expect(abs(heights.reduce(0, +) - 400) < 0.5)
        #expect(heights.allSatisfy { $0 >= 72 - 0.01 })
        #expect(heights[0] > heights[1])
        // 放不下保底高度时平均分，也不超出
        let tight = TreemapLayout.rowHeights([10, 1, 1, 1, 1, 1, 1], total: 16, height: 300)
        #expect(abs(tight.reduce(0, +) - 300) < 0.5)
    }
}
