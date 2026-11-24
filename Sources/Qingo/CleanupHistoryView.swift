import SwiftUI

/// Full-bleed inline Cleanup History main page (replaces the old modal sheet).
struct CleanupHistoryView: View {
    @ObservedObject var store: ScanStore

    private var totalMovedBytes: Int64 {
        store.cleanupHistory.reduce(0) { sum, entry in
            let add = sum.addingReportingOverflow(entry.effectiveBytes)
            return add.overflow ? Int64.max : add.partialValue
        }
    }

    private var totalMovedItems: Int {
        store.cleanupHistory.reduce(0) { $0 + $1.effectiveCount }
    }

    var body: some View {
        ScrollView {
            GlassGroup {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: "clock.arrow.circlepath", tint: Theme.indigo, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("清理记录").font(.system(size: 21, weight: .bold))
                            Text("记录每次清理的项目数、估算大小与同卷可用空间变化。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 12)
                        if store.cleanupHistory.contains(where: { $0.volumes?.isEmpty == false }) {
                            Button(store.readingHistoryVolumes ? "正在刷新…" : "刷新可用空间", action: store.refreshHistoryVolumes)
                                .buttonStyle(ToolbarButtonStyle(tinted: true))
                                .disabled(store.readingHistoryVolumes)
                        }
                        Button("返回") {
                            store.navigate(to: store.destination)
                        }
                        .buttonStyle(ToolbarButtonStyle(tinted: false))
                    }

                    // Summary KPI bar
                    HStack(spacing: 12) {
                        summaryPill(title: store.cleanupHistory.isEmpty ? "最近记录合计" : "最近 \(store.cleanupHistory.count) 次合计",
                                    value: ByteFormat.string(totalMovedBytes), tint: Theme.blue)
                        summaryPill(title: "保留记录次数", value: "\(store.cleanupHistory.count) 次", tint: Theme.indigo)
                        summaryPill(title: "合计处理项目", value: "\(totalMovedItems) 项", tint: Theme.green)
                    }

                    if store.cleanupHistory.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.ink3)
                            Text("暂无清理记录")
                                .font(.system(size: 15, weight: .semibold))
                            Text("完成一次清理后，这里会保留明细与同卷空间变化。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .glass(radius: 14)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.cleanupHistory.indices, id: \.self) { index in
                                entryRow(store.cleanupHistory[index])
                            }
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private func summaryPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glass(radius: 13)
    }

    private func entryRow(_ entry: CleanupLog.Entry) -> some View {
        let bytes = entry.effectiveBytes
        let count = entry.effectiveCount
        let dispositionText: String
        let disclosureTitle: String
        switch entry.resolvedDisposition {
        case .purged:
            dispositionText = "直接永久释放 \(count) 项（不可恢复）"
            disclosureTitle = "查看已永久释放的 \(entry.moved.count) 项"
        case .emptiedTrash:
            dispositionText = "清空废纸篓 \(count) 项（不可恢复）"
            disclosureTitle = "查看已清空的 \(entry.moved.count) 项"
        case .trashed:
            dispositionText = "移到废纸篓 \(count) 项（可恢复）"
            disclosureTitle = "查看已移动的 \(entry.moved.count) 项"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.action).font(.system(size: 14.5, weight: .semibold))
                Spacer()
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.blue)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                Text(dispositionText)
                if entry.failedCount > 0 {
                    Text("未清理 \(entry.failedCount) 项").foregroundStyle(Theme.amber)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink2)

            ForEach(entry.volumes ?? []) { volume in
                volumeRow(volume, disposition: entry.resolvedDisposition)
            }
            ForEach((entry.failureReasons ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                Text("\(count) 项未清理：\(reason)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.amber)
            }
            if !entry.moved.isEmpty {
                DisclosureGroup(disclosureTitle) {
                    VStack(spacing: 4) {
                        ForEach(entry.moved.indices, id: \.self) { index in
                            let item = entry.moved[index]
                            HStack {
                                Text(item.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.ink2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.path)
                                Spacer(minLength: 12)
                                Text(ByteFormat.string(item.bytes))
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12.5))
            }
        }
        .padding(16)
        .glass(radius: 13)
    }

    private func volumeRow(_ volume: CleanupVolumeReading, disposition: CleanupLog.Entry.Disposition) -> some View {
        let latest = store.historyReadings[volume.id]
        let verb = disposition == .trashed ? "移动" : "清理"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(volume.before.label).fontWeight(.semibold)
                Text("\(verb)前 \(ByteFormat.string(volume.before.available))")
                if let after = volume.afterMove, let delta = after.change(since: volume.before) {
                    Text("\(verb)后 \(ByteFormat.string(after.available))（\(formattedChange(delta))）")
                }
            }
            if let latest, let delta = latest.change(since: volume.before) {
                if let after = volume.afterMove, let sinceMove = latest.change(since: after) {
                    Text("当前可用 \(ByteFormat.string(latest.available))（较\(verb)后\(formattedChange(sinceMove))）")
                } else {
                    Text("当前可用 \(ByteFormat.string(latest.available))（较\(verb)前\(formattedChange(delta))）")
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink2)
        .padding(.vertical, 2)
    }

    private func formattedChange(_ bytes: Int64) -> String {
        if bytes == 0 { return "无变化" }
        return (bytes > 0 ? "增加 " : "减少 ") + ByteFormat.string(abs(bytes))
    }
}
