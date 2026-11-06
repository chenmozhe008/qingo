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
