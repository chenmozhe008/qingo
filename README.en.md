<div align="center">

<img src="docs/images/icon.png" width="128" alt="Qingo icon">

# Qingo

**A Mac cleaner for the AI era**

Built for video creators and developers. Qingo recognizes the caches of 60+ editing, design and AI tools<br>
— CapCut, DaVinci Resolve, Adobe apps, Codex, Claude Code, Cursor and more —<br>
and clears them in one click without touching projects, footage or conversations.

[简体中文](README.md) | English

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-orange?logo=swift)

<img src="docs/images/overview-light.png" alt="Qingo overview (light)" width="900">

</div>

AI tools and creative software leave runtimes, caches and model files on the Mac that often add up to many gigabytes. General-purpose cleaners struggle to tell what can be rebuilt from what is a conversation or a piece of work. Qingo identifies these files tool by tool: it clears caches that rebuild automatically and keeps projects, conversations and models.

Qingo (小清) is a native SwiftUI app with light, dark and automatic appearance, using the system Liquid Glass effect on macOS 26.

> **Language note:** the app interface is currently available in Simplified Chinese only.

## Highlights

- **AI coding tools**: Cursor, Claude Code, Codex, WorkBuddy, CodeBuddy, Trae, Qoder and other AI coding and agent tools, plus local models such as Ollama and LM Studio. Runtime files, downloaded packages, UI caches and logs are cleared; conversations, workspaces, extensions and models are kept
- **Video and design software**: CapCut (Jianying), DaVinci Resolve, After Effects, Premiere Pro, Final Cut Pro, Blender and more. CapCut caches, the AE disk cache and the Adobe media cache are cleared directly; for DaVinci Resolve and Final Cut Pro render caches, Qingo shows where to clear them inside the app. Projects, drafts and footage are kept
- **One-click cleaning**: only caches that rebuild automatically are listed, all selected by default. Cleaning works even while the apps are running. Files are moved to the Trash and can be restored; the Trash is never emptied automatically
- **Developer caches**: build caches in your code folders are listed per project on a separate page, never mixed into one-click cleaning
- **Open source and offline**: every cleaning rule is in the source code. No network access, no data upload; scan results stay on your Mac

## Screenshots

| Creative & AI tools: caches separated from work | WeChat & WeCom: usage and in-app cleanup path |
| --- | --- |
| <img src="docs/images/tools.png" alt="Creative and AI tools"> | <img src="docs/images/wechat.png" alt="WeChat and WeCom"> |
| **Developer caches, listed per project** | **Dark mode** |
| <img src="docs/images/dev.png" alt="Developer caches"> | <img src="docs/images/overview-dark.png" alt="Dark mode"> |

## What Qingo scans

| Category | Contents | Handling |
| --- | --- | --- |
| Cleanable caches | App caches, npm / pip / uv package caches, update installers | One-click cleaning, all selected by default |
| Creative & AI tools | Grouped into editing & color, design & 3D, AI image & video, AI assistants, AI coding & agents, local models | Only rebuildable caches and logs are listed |
| WeChat & WeCom | Space used and where to clean it inside WeChat | Never deleted; path only |
| Large files | Files, installers and project folders over 1 GB (full scan) | Files and installers require confirmation; project folders show size only |

A quick scan checks common caches and known tool folders, usually in a few seconds to a few dozen seconds; a full scan covers your entire home folder.

The **Tools** section of the sidebar also includes an **app uninstaller**, which moves an app together with its support files, caches, preferences and background items in `~/Library` to the Trash (restorable), and a cleaner for leftovers of already-deleted apps.

## Installation

Requires macOS 14 Sonoma or later on Apple silicon (M1 or newer).

1. Download `Qingo-<version>.zip` from [Releases](https://github.com/chenmozhe008/qingo/releases/latest), unzip it and drag Qingo into Applications
2. On first launch macOS will report that it cannot verify the developer (Qingo is not notarized). Open **System Settings → Privacy & Security** and click **Open Anyway** near the bottom. Alternatively run the following in Terminal, then open the app normally:

   ```
   xattr -dr com.apple.quarantine /Applications/小清.app
   ```
3. To include WeChat and other protected folders in scans, enable Qingo under **System Settings → Privacy & Security → Full Disk Access**

## Safety

- Scanning is read-only, does not follow symbolic links and does not cross volumes
- Only automatically rebuildable content is listed; anything that cannot be confirmed safe (conversations, work, models, dependencies) is never listed
- File identity is re-checked right before cleaning; changed files are skipped
- Cleaning only moves files to the Trash and can be undone
- Chat app data, credential folders (`.ssh`, `.aws`, etc.) and project files are always protected; for Xcode only the DerivedData build cache is cleared

## Build from source

```sh
git clone https://github.com/chenmozhe008/qingo.git
cd qingo
./script/build_and_run.sh --package   # builds dist/小清.app
./script/test.sh                      # runs tests
```

Tool definitions live in [`Sources/Qingo/CreativeApps.swift`](Sources/Qingo/CreativeApps.swift). Pull requests adding new tools are welcome — please cite the source of each path.

## Feedback

[GitHub Issues](https://github.com/chenmozhe008/qingo/issues)

## License

[MIT](LICENSE) © 沉默者之二
