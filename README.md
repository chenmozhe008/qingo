<div align="center">

<img src="docs/images/icon.png" width="128" alt="小清图标">

# 小清：Mac 清理工具

**Qingo**，AI 时代的 Mac 清理工具

认得 Cursor、Claude Code、Codex、剪映、达芬奇……缓存一键清理，项目、对话和模型不受影响。

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange?logo=swift)

<img src="docs/images/overview-light.png" alt="总览（浅色）" width="900">

</div>

AI 工具和创作软件会在 Mac 上留下大量运行时、缓存和模型文件，常达数 GB。通用清理工具难以区分哪些可以重建、哪些是对话和作品。小清按工具识别这些文件：清理可重建的缓存，保留项目、对话和模型。

原生 SwiftUI 应用，支持浅色 / 深色 / 自动外观，macOS 26 上使用系统液态玻璃效果。

## 它的优势

- **识别 AI Coding 工具**：支持 Cursor、Claude Code、Codex、WorkBuddy、CodeBuddy、Trae、Qoder 等主流 AI Coding 与智能体工具，以及 Ollama、LM Studio 等本地模型。清理运行时、下载包、界面缓存和日志；保留对话记录、工作区、扩展和模型。
- **识别影视创作软件**：支持剪映、达芬奇、After Effects、Premiere、Final Cut、Blender 等剪辑和设计软件。直接清理剪映缓存、AE 磁盘缓存和 Adobe 媒体缓存；达芬奇、Final Cut 的渲染缓存提供软件内清理路径；保留项目、草稿和素材。
- **一键清理**：只列出可自动重建的缓存，默认全选，点击即清理，软件运行时也可清理。文件移到废纸篓，可撤销；不会自动清空废纸篓。
- **开源**：清理规则全部在代码中，可供查验。不联网，不上传数据，扫描结果仅保存在本机。

## 截图

| 创作与 AI 工具：按工具区分缓存和作品 | 微信与企业微信：显示占用和微信内清理路径 |
| --- | --- |
| <img src="docs/images/tools.png" alt="创作与 AI 工具"> | <img src="docs/images/wechat.png" alt="微信与企业微信"> |
| **扫描中：实时显示发现的内容** | **深色模式** |
| <img src="docs/images/scan.png" alt="扫描中"> | <img src="docs/images/overview-dark.png" alt="深色模式"> |

<p align="center"><img src="docs/images/about.png" alt="关于" width="720"></p>

## 能看到什么

| 分类 | 内容 | 能不能在这里清 |
| --- | --- | --- |
| 可清理缓存 | 应用缓存、npm / pip / uv 等包缓存、更新安装包 | 可以，默认全选 |
| 创作与 AI 工具 | 按「剪辑与调色 / 设计与三维 / AI 生图与视频 / AI 助手 / AI Coding 与智能体 / 本地模型」分组 | 只列出可重建的缓存和日志 |
| 微信与企业微信 | 占用大小和微信内的清理路径 | 不删除，仅提供路径 |
| 大文件 | 超过 1 GB 的文件、安装包和项目文件夹（完整扫描） | 文件和安装包需确认后删除，项目文件夹仅显示大小 |

快速扫描只检查常见缓存和已识别工具的目录，通常几秒到几十秒；完整扫描检查整个用户目录。

左栏「工具」中另有两项：

- **卸载应用**：将应用及其在 `~/Library` 中的支持文件、缓存、偏好设置、窗口状态和后台程序一并移到废纸篓，可撤销。仅按 bundle id 和应用名在固定目录中精确匹配，包括该应用的对话、模型和设置；不读取、不删除沙盒数据（Containers）。另提供「已删除应用的残留」清理，匹配规则严格，默认全选。
- **开发项目**：在代码文件夹（默认 `~/Coding`）中按项目列出构建缓存，清理后会自动重建。不影响代码、依赖和虚拟环境。

## 下载安装

要求：macOS 14 Sonoma 及以上，Apple 芯片（M1 及更新）。

1. 在 [Releases](https://github.com/chenmozhe008/qingo/releases/latest) 下载 `Qingo-<版本>.zip`，双击解压，将「小清」拖到「应用程序」文件夹。
2. 首次打开时，系统会提示无法验证开发者（小清未经 Apple 公证）。打开「系统设置 → 隐私与安全性」，在页面下方点击「仍要打开」，再确认一次即可。之后正常打开。
3. 如需扫描微信占用和更多缓存，在「系统设置 → 隐私与安全性 → 完全磁盘访问」中开启「小清」。

## 从源代码构建

需要 Xcode 或 Swift 命令行工具：

```sh
git clone https://github.com/chenmozhe008/qingo.git
cd qingo
./script/build_and_run.sh --package   # 生成 dist/小清.app
./script/test.sh                      # 运行测试
./script/package_release.sh           # 生成发布用的 tmp/release/Qingo-<版本>.zip
```

本机有 Apple Development 证书时用它签名，没有时自动使用临时签名（ad-hoc）。发布包统一使用临时签名并去除调试符号，不含构建机器的信息。

## 加一个新工具

工具清单在 [`Sources/Qingo/CreativeApps.swift`](Sources/Qingo/CreativeApps.swift)。每个工具一行：

- `folders`：它在 `~/Library/Application Support` 和 `~/Library/Caches` 下的文件夹名
- `roots`：它在用户目录下的数据目录（只统计，不删除）
- `caches`：确定可以重新生成的缓存目录（可清理）

无法确认的路径只放进 `folders` 或 `roots`，不要放进 `caches`。欢迎提交 PR，请附上路径来源。

## 安全边界

- 扫描只读，不跟随符号链接，不跨卷。
- 只列出可自动重建的内容，默认全选，一键清理；无法确认安全的内容（对话、作品、模型、依赖）不会列出。
- 「大文件」例外：文件和安装包需手动选择并确认；项目文件夹仅显示大小。
- 清理前再次核对文件身份，文件发生变化即跳过。缓存在软件运行时也可清理（软件会自动重建）；大文件正在使用时跳过。
- 清理后可撤销，将文件恢复到原位置。
- 清理只移到废纸篓，不做永久删除。
- 聊天软件数据、凭据目录（`.ssh`、`.aws` 等）、项目文件始终受保护；Xcode 只清 DerivedData 构建缓存。

## 反馈

- [GitHub Issues](https://github.com/chenmozhe008/qingo/issues)
- 邮件：327529709@qq.com

更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE) © 沉默者之二

> 小清原名「Mac 清理管家」，1.1.0 起改名。
