import Foundation

struct HistoryEntry: Identifiable, Equatable, Sendable {
    let version: String
    let date: String
    let notes: [String]
    let page: URL?
    let isDevelopment: Bool

    var id: String { version + (isDevelopment ? "-dev" : "-release") }
}

/// Ported from Shandian Download: merges local `CHANGELOG.md` development/offline records with
/// live GitHub Releases API notes so the About › 更新记录 page is always authoritative and crisp.
enum ReleaseHistory {
    static func local(_ text: String, includeDevelopment: Bool) -> [HistoryEntry] {
        var rows: [(String, [String])] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                rows.append((String(line.dropFirst(3)), []))
            } else if line.hasPrefix("- "), !rows.isEmpty {
                rows[rows.count - 1].1.append(String(line.dropFirst(2)))
            }
        }
        return rows.compactMap { title, notes in
            let isDevelopment = title.hasSuffix("（开发版）")
            guard includeDevelopment || !isDevelopment else { return nil }
            let parts = title.components(separatedBy: " · ")
            let version = parts[0].trimmingCharacters(in: .whitespaces)
            let date = parts.dropFirst().first?.replacingOccurrences(of: "（开发版）", with: "") ?? ""
            return HistoryEntry(
                version: version,
                date: date,
                notes: notes,
                page: nil,
                isDevelopment: isDevelopment
            )
        }
    }

    static func online(_ data: Data) -> [HistoryEntry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return json.compactMap { item in
            guard item["draft"] as? Bool == false,
                  item["prerelease"] as? Bool == false,
                  let tag = item["tag_name"] as? String,
                  tag.hasPrefix("v"),
                  tag.dropFirst().split(separator: ".").allSatisfy({ Int($0) != nil }),
                  let address = item["html_url"] as? String,
                  let page = URL(string: address) else { return nil }
            let body = item["body"] as? String ?? ""
            let allNotes = body.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).replacingOccurrences(of: "**", with: "") }
            let sectionNotes = UpdateChecker.notes(body)
            return HistoryEntry(
                version: String(tag.dropFirst()),
                date: String((item["published_at"] as? String ?? "").prefix(10)),
                notes: sectionNotes.isEmpty ? allNotes : sectionNotes,
                page: page,
                isDevelopment: false
            )
        }
    }

    static func merge(local: [HistoryEntry], online: [HistoryEntry]) -> [HistoryEntry] {
        var result = online
        for row in local {
            if row.isDevelopment {
                result.append(row)
            } else if let index = result.firstIndex(where: { $0.version == row.version }) {
                let published = result[index]
                result[index] = HistoryEntry(
                    version: row.version,
                    date: published.date.isEmpty ? row.date : published.date,
                    notes: published.notes.isEmpty ? row.notes : published.notes,
                    page: published.page,
                    isDevelopment: false
                )
            } else {
                result.append(row)
            }
        }
        return result.sorted {
            if $0.version == $1.version { return $0.isDevelopment && !$1.isDevelopment }
            return UpdateChecker.isNewer($0.version, than: $1.version)
        }
    }
}
