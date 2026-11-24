import Foundation

/// Extended developer & toolchain caches beyond basic npm/pip/DerivedData.
/// All paths listed here are regenerable caches or re-downloadable debug symbols.
enum DeveloperCaches {
    struct Entry: Sendable {
        let relativePath: String
        let note: String
        let isHighConfidenceA: Bool
    }

    static let entries: [Entry] = [
        Entry(relativePath: "Library/Developer/Xcode/Previews",
              note: "Xcode SwiftUI 预览缓存，下次打开预览时会自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Developer/CoreSimulator/Caches",
              note: "iOS 模拟器运行时缓存，下次启动模拟器时自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
              note: "iOS 真机调试符号缓存，连接对应系统版本的设备时会重新生成。",
              isHighConfidenceA: false),
        Entry(relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
              note: "watchOS 真机调试符号缓存，连接对应设备时会重新生成。",
              isHighConfidenceA: false),
        Entry(relativePath: "Library/Developer/Xcode/tvOS DeviceSupport",
              note: "tvOS 真机调试符号缓存，连接对应设备时会重新生成。",
              isHighConfidenceA: false),
        Entry(relativePath: "Library/Caches/CocoaPods",
              note: "CocoaPods 依赖下载缓存，下次安装时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/org.swift.swiftpm",
              note: "Swift Package Manager 包缓存，下次解析依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/go-build",
              note: "Go 编译构建缓存，下次编译时自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: ".gradle/caches",
              note: "Gradle 全局构建与依赖缓存，下次构建时自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: ".cargo/registry/cache",
              note: "Rust Cargo 包下载缓存，下次构建时自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: ".cache/yarn",
              note: "Yarn 包缓存，下次安装依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/Yarn",
              note: "Yarn 包缓存，下次安装依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/pip",
              note: "pip Python 包下载缓存，下次安装依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/pypoetry",
              note: "Poetry 包缓存，下次安装依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/JetBrains",
              note: "JetBrains IDE 索引与编译缓存，下次打开会自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/Cypress",
              note: "Cypress 自动化测试浏览器缓存，需要时可重新安装。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/deno",
              note: "Deno 运行时与依赖缓存，下次运行时自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/typescript",
              note: "TypeScript 语言服务缓存，下次打开编辑器自动重建。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/composer",
              note: "PHP Composer 包缓存，下次安装时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Caches/node-gyp",
              note: "node-gyp 编译头文件缓存，编译原生模块时自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: ".bun/install/cache",
              note: "Bun 包安装缓存，下次安装依赖时会自动重新下载。",
              isHighConfidenceA: true),
        Entry(relativePath: "Library/Developer/CoreSimulator/Logs",
              note: "iOS 模拟器历史运行日志，清理不影响模拟器系统与数据。",
              isHighConfidenceA: true)
    ]

    /// Subfolders explicitly allowed inside the otherwise protected `~/Library/Developer/Xcode` root.
    static let allowedXcodeSubfolders: [String] = [
        "DerivedData",
        "Previews",
        "iOS DeviceSupport",
        "watchOS DeviceSupport",
        "tvOS DeviceSupport"
    ]

    static func locations(home: URL) -> [URL] {
        entries.map { home.appending(path: $0.relativePath) }
    }

    static func match(for url: URL, home: URL) -> Entry? {
        let path = CanonicalPath.url(url).path
        return entries.first { home.appending(path: $0.relativePath).path == path }
    }
}
