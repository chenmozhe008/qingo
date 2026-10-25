# 小清 Qingo（原名 Mac 清理管家 / MacSpaceKeeper）

原生 SwiftUI 磁盘扫描/缓存清理 App。功能说明看 README.md。

- 名字（2026-10-21 用户定）：中文「小清」、英文「Qingo」；**出现名字的地方都要带「Mac 清理工具」**（侧栏、欢迎页、关于、README、仓库简介），光写「小清」别人不知道是干嘛的；名字里不带 Mac（以后可能做 Windows）。图标暂不改（出过三版方案，用户选择先保留，稿在 `output/mockups/qingo-icon/`）
- 身份：Swift 模块/可执行文件 `Qingo`，bundle id `io.github.chenmozhe008.qingo`；旧身份 `com.forwardyan.MacSpaceKeeper` 的设置和 `Application Support/MacSpaceKeeper/results` 由 `LegacyMigration` 带过来，别删
- 分发：走 GitHub Releases（以后再做公证），**不上 Mac App Store**（沙盒读不了 ~/Library 和其他应用目录，核心功能会废）

## 版本与发布

- 版本号写在 `script/build_and_run.sh` 的 `APP_VERSION`，构建号取 git 提交数；改版本时同步在 `CHANGELOG.md` 顶部加一节（App「关于」页直接读这个文件，别另写一份）
- 作者 @沉默者之二、反馈邮箱在 `AboutView.swift` 的 `AppInfo`；「关于」三页（介绍 / 更新记录 / 反馈）。标题区＝App 图标 +「小清 Qingo」+ 版本作者 + GitHub 按钮；介绍卡里有醒目的「代码完全开源」卡片；介绍页顺序：介绍卡（标题「AI 时代的 Mac 清理工具」无句号 + 一段说明，不以具体工具名开头）→ 优势（三张卡）→ 对比与说明。定位（2026-10-21 用户定）：**AI 时代的清理工具**，AI Coding 是主卖点、影视创作是加分（只是排序，界面上不写「加分项」）；措辞用「AI Coding」不用「AI 编程」；不写具体识别了多少款（写「主流工具」）；不对竞品下没查证的断言；正文字号不小于 13；竞品对比数据在 `Comparison`（2026-10-21 查官网与评测，查不到的格子写「—」，别凭印象补；界面上不写这类内部说明）
- 左栏扫描位置叫「快速扫描 / 完整扫描」（2026-10-21 定，别再叫「常见缓存 / 我的文件」）
- 外观三选一（`AppearanceMode`，rawValue「跟随系统」存在 defaults 里别改）。**只走 AppKit（`NSApp.appearance` + 清掉各窗口的 appearance），不用 SwiftUI `preferredColorScheme`**——它设过 .dark 后再设 nil 不会恢复，导致深色→自动仍是深色（用户报过）。「自动」＝白天浅色、夜间深色：系统外观本身是「自动」时跟系统（按日落），否则 7:00–19:00 算白天，每分钟检查一次；侧栏开关写字「自动 / 浅色 / 深色」（光一个半圆图标看不懂）。**分段控件的选中项用 `Theme.raised`（比底槽浅、带阴影），不许比底槽深**——深色下会像按黑了（用户指出）；GitHub 用 `GitHubMark`（官方 mark 的 SVG），不用 `</>` 符号；颜色一律用 `Theme` 里的 adaptive 色和 `Theme.fill()`，**不要再写死 `Color.white`**（彩色底上的白字除外）
- 导航：左栏顶部「总览」；子页（创作工具/微信）左上大号「‹ 返回总览」；再点当前位置也回总览；「关于与反馈」只在左栏底部一处
- 视觉：macOS 26+ 卡片走原生 `glassEffect`（液态玻璃），窗口透明 + 背后模糊；更早系统回落磨砂（`Theme.glass`）。**别把 `glass()` 换成不透明色块、别把 `Backdrop` 底色调到不透明**（1.0.4 中途被改成 97% 不透明，玻璃效果全没了，用户点名）
- 总览（2026-10-25 定稿方案 D「先说结果」，效果图 `output/mockups/k-d-outcome.png`；按苹果原则：内容优先、一眼看懂、先说结果、主操作就在眼前、渐进展开）：`showingOverview` 独立页 = 左侧空间圆环 + 右侧「N 处缓存…／可以放心腾出／X」+ 胶囊主按钮「清理 X」（`HeroButtonStyle`）+「查看这 N 处 ›」（左侧是 `SpaceRing`），底部四张分类卡（玻璃，点进分类页）。分类页只有标题和列表，不再重复统计卡
- 空间圆环 `SpaceRing`（2026-10-25 用户看图选方案 ①，效果图 `output/mockups/m-overview-1-ring.png`）：一整圈粗圆环，有色弧＝已用、缺口＝可用，够用蓝色、< 10 GB 橙色；中间「现在可用 / X / 共 Y」。**只回答「还剩多少」**，「被谁占了」交给四张分类卡，所以不要图例。**不许写「清理后 X」**——清理只是进废纸篓，清空前空间不变（用户指出过这是错的）。之前的分色刻度表盘被否：要配图例才看得懂
- 所有页面同一套页头 `PageHeader`：彩色图块 + 页面名 + 一句「这里是什么、会怎样」+ 右侧主按钮（胶囊 `HeroButtonStyle`）。主按钮不放底部工具条（底部工具条已删）；**分类页的清理按钮只清本页勾选**（`ScanStore.reviewCleanup(scope:)`），总览的按钮清全部。扫描中用同款圆环转圈；欢迎页、未扫描页、确认弹窗也用胶囊主按钮
- **配色（2026-10-25 用户嫌蓝紫渐变「挺大众」，要 App Store 头部应用那种美学）**：一个标志色「天青」（取「小清」的清，宋瓷天青釉），按钮、圆环、链接、选中都用它；背景是安静的暖白（深色是石墨灰），左上角带一点天青的光；分类色低饱和成套：缓存天青、创作珊瑚、微信竹青、大文件藕紫、卸载赭橙、开发黛蓝。`Theme.blue` 这个名字保留，值已是天青。App 图标暂仍是蓝色（用户之前定过不改图标）
- 背景随空间状态变：剩余 ≥ 10 GB 是上面的安静底色，< 10 GB 变暖（`Backdrop(warm:)`）
- **最小窗口（960×640）下不许挤坏**：胶囊主按钮永不折行（`HeroButtonStyle` 自带 lineLimit+fixedSize）；总览窄时圆环缩小、按钮和「查看」上下排、分类卡两行两列；卸载页窄时列表收窄、卸载按钮挪到名字下面；`PageHeader` 放不下时按钮挪到标题下面。改界面必须用 `--window-size=960x640` 截一张验
- 图标：侧栏全部用 SF Symbols 实心彩色图块（`IconTile`）。总览＝仪表、快速扫描＝闪电、完整扫描＝硬盘、文件夹＝文件夹、创作与 AI＝魔棒、微信＝对话气泡、大文件＝文档、卸载＝垃圾桶、开发工程＝锤子；当前扫描位置的图块是蓝色、其余灰色，行底色只给当前页面（总览/分类/工具），避免两行同时像被选中
- 背景 `Backdrop` 是柔和的 MeshGradient 色场（macOS 15+），液态玻璃要有东西可折射才看得出来，别换回纯色
- 子页「返回总览」用标志色 tinted 按钮（`ToolbarButtonStyle(tinted:)`），别做成灰的
- 磁盘可用空间一律**实时读** `volumeAvailableCapacityForImportantUsage`（与访达一致），不用扫描时存下的数
- GitHub **公开仓库**（MIT，2026-10-21 开源）：chenmozhe008/qingo。仓库里不放密钥、个人路径和个人配置；`SafetyPolicy` 的保护名单只写通用目录。README 面向公众，内部约定写本文件
- 文案风格（2026-10-21 定，10-25 两次强调）：**像专业 Mac 软件，不像 AI 聊天**。参照 macOS 和成熟清理工具：短句、中性、陈述事实；用「清理 / 移到废纸篓（Apple 原词，不说"放进"）/ 可自动重建 / 需手动确认 / 仅显示占用 / 未清理 / 正在运行」这类标准说法。**不写**：口语和打包票（一个不碰、放心清、拿不准、删不删由你决定、教你点哪里、这台 Mac 很干净、哗一下）、对用户喊话的「你…」句、第一人称「我」、程序腔（没有项目被移动）。一行只说一件事，不用「·」串信息；失败原因写清是什么情况；显示 App 名不显示文件夹名；竞品只写查证过的事实。CHANGELOG 会显示在「关于 → 更新记录」，按正式更新说明写

## 构建与安装

- 打包：`./script/build_and_run.sh --package` → `dist/小清.app`
- 安装：覆盖到 `~/Applications/小清.app`（用户日常从这里打开）
- `dist/` 里只保留这一个 App；旧名字的包（如 `MacSpaceKeeper.app`）会被误开成旧版，发现就清掉
- `swift test` 在只有命令行工具（无 Xcode）的环境下会报 TestingMacros 插件缺失，属于环境问题；用 `./script/test.sh`
- `script/test.sh` 设 `QINGO_RESULTS_DIR` 到临时目录，测试的扫描结果不写进真实的 results 目录（之前漏了，留下几十个 /var/folders 的结果文件）
- 测试共用一个 defaults 域且并行跑：测 `ScanStore` 选择逻辑时要显式设 `store.filter`，别依赖默认分类

## 界面结构（2026-10-20 定稿：效果图 B「沉浸品牌感」）

定稿效果图在 `output/mockups/b-*.png`（HTML 源同目录）。改 UI 先对照效果图，大改先出新效果图给用户选，不在代码里一轮轮试。

- 天青标志色 + 安静底色 + 玻璃卡片（2026-10-25 起，取代原深色蓝紫渐变），配色和通用组件集中在 `Theme.swift`（`glass()`、`GlowBar`、`UsageRing`、按钮样式）
- 欢迎页：大图标 + 圆形发光「快速扫描」+ 底部磁盘容量卡；无侧栏
- 结果页：左侧栏（扫描位置 + 分类）；顶部环形图（磁盘可用）+ 2×2 统计卡（点卡片切分类）；下方列表，点行展开说明/路径/Finder；底部操作条
- 窗口用 `.hiddenTitleBar`，内容顶到标题栏，左上留红绿灯位置
- 场景是单个 `Window`（2026-10-25）：关窗口即退出，点 Dock 图标重新打开。别换回 `WindowGroup` + 删 `.newItem`——那样关窗后进程还在、点图标也叫不出窗口（用户反馈过）
- 列表交互：点行=选中（可清理项），行尾 ⓘ=展开详情；选中行青色底+左侧色条（第二档用琥珀色）；底部「全选 ⌘A / 只选可再生」只管第一档
- 条目显示名走 `ItemPresentation`（bundle id→App 名+图标，常见缓存目录→中文名），原始目录名留在副标题
- 分类色：可清理缓存=青、需要判断=琥珀、大文件与工程=紫
- 已删「目录占用」分类（用户看不懂、不可操作）；工程/应用数据 < 200 MB 不列入（`minProjectBytes`）

- 本机只有命令行工具，**`@State` 等 SwiftUI 宏编译不过**（缺 SwiftUIMacros 插件，2026-10-25 复核仍如此）。视图状态一律放进 `ScanStore` 的 `@Published`

## 性能（2026-10-25 用户反馈「往下滑很慢很卡」）

- 根因：滚动时鼠标经过每一行都改 `ScanStore.hoveredID` → 整个窗口重画；而每次重画按分类筛 300 多项、每项都跑 `CreativeApp.of` 路径匹配，调试版实测 **675 ms/次**
- 规矩：
  - **会频繁变化的状态（悬停）不放 `ScanStore`**：列表行用 `HoverTracker` + `HoverFill`，只有行背景跟着重画；`hoveredID` 只给侧栏文件夹行
  - **body 里不做按项的重计算**：分类结果在 `result` 的 didSet 里算一次（`itemsByCategory`），`CreativeApp.of` 有路径缓存，图标走 `ItemPresentation.icon(forPath:)` 缓存；新加的按项判断照此办理
  - 多张玻璃卡片的滚动页包 `GlassGroup`（macOS 26 的 `GlassEffectContainer`）
  - 打包用 `swift build -c release`（调试版慢几倍）

## 分类与功能（2026-10-21）

- 分类（`ItemFilter`）：可清理缓存（青）/ 创作与 AI 工具（粉）/ 微信与企业微信（绿）/ 需要判断（琥珀）/ 大文件与工程（紫）。界面名走 `ItemFilter.title`；`.creative` 的 rawValue 仍是「剪辑与设计软件」（存在 UserDefaults `lastFilter` 里，别改）
- 创作与 AI 工具（2026-10-21 用户定：**国内外同类软件都要覆盖**，自己没装的别人也会用）：清单在 `CreativeApps.swift`，按 6 组（剪辑与调色 / 设计与三维 / AI 生图与视频 / AI 助手 / AI Coding 与智能体 / 本地模型）。规则：工具目录整体只读（`dataOwner`）；能清的只有它在 `~/Library/Caches` 的文件夹、`caches` 里列出的目录、应用目录下一层的浏览器内核缓存（`engineCaches`）。加新工具只改这个文件；**拿不准的路径只放 folders/roots（只读），不放 caches**
- 工具数据里自动认作可清理的（2026-10-25 用户问「WorkBuddy 不知道怎么清理，能直接清吗」后加，`CreativeApp.cacheNote`）：`Application Support/<工具>/` 下一层的内核缓存；更深处的内核缓存只在**上一级是浏览器配置目录**（有 `Preferences`/`Local State` 或在 `Partitions` 里）时才算；任意深度的 `Crashpad`/`crashpad`；工具顶层目录下的 `logs`/`Logs`；`~/Library/Logs/<认得的工具>`。**不认的**：名字带 cache 的普通文件夹（如 WorkBuddy 的 `plugins/cache`，同类工具在这里放已装插件）、`~/Library/Logs` 整体（里面有用户自己定时任务的日志）
- 只读数据行的按钮是「里面有什么」（2026-10-25 用户：「查看位置点进去也不知道怎么删」）：点开按子文件夹拆成白话（`DataBreakdown.describe`：对话记录 / 插件和扩展 / 登录状态 / 运行环境…），每项写怎么处理；只在名字看不懂的大子文件夹里往下钻一层；认不出的老实写「用途不明，建议别动」。行名也按内容叫（「最近的对话记录」），认不出才叫「本地数据」。`cleanHow` 只写查证过的做法
- 旧对话/旧图片（`SafetyPolicy.oldToolHistory`，30 天没动）：Codex 的 `~/.codex/sessions/年/月/日` 和 `generated_images/<会话>` 按天/按会话列为第二档。`~/.codex` 仍在保护名单，只放开 sessions / archived_sessions / generated_images 三个子目录（登录凭据、设置、记忆、数据库不碰）。Claude Code 自己默认只留 30 天，不另做
- 同一工具里第二档同类项也合成一行（如「30 天前的对话记录，共 55 处」，琥珀色）；模型仍一个一行
- 页面：按组分区、每个工具一张卡（缓存可勾选 / 单个模型确认后可删 / 本地数据只读带「在 XX 里处理」）；一个工具有 2 处以上可清理项时合成一行「可以清理」（写种类和处数，点行全选、箭头展开明细；用户嫌零碎行太多，2026-10-25）；已安装没占用的合成一行；底部可展开「能识别的 N 款工具」。命令行工具没有 App 图标时用 `iconApp` 借厂商 App 图标，否则按组配色的图标块
- 只读数据 < 1 MB 不列（`minToolDataBytes`）；Containers 下的沙盒目录不碰（读它会触发系统授权弹窗）
- 微信 / 企业微信：**只读量大小，永不提供删除**（`DiskScanner.chatAppUsage`）。按文件夹估算拆成几块（`ChatPart`，界面写「大约」）：微信 `xwechat_files/*/msg`＝聊天里的图片和文件（自己挑）、`db_storage`＝聊天记录（别删）、`app_data`/`.wxapplet`＝缓存（放心清）；企业微信 `Profiles/*/Caches`＝聊天里的文件、`cefcache`+`Profiles/*/Publishsys`＋日志＝缓存、`WeDrive`＝微盘文件（你的文件）；其余＝其他。2026-10-25 实测本机微信 17.6 GB 里缓存只占 2 GB——页面要照实说「能一键清的大约 X，大头要自己挑」，别只写「建议清理」
- 微信页只讲方法（2026-10-25 用户：「自己挑 / 别删」那种拆分不具备操作性）：占了多少 → 打开哪里（菜单路径）→ 到了这一页点什么，每步写「大约 X」。不再列拆分行和标签
- 清理步骤按用户实际点过的写（2026-10-25）：微信「左下角 ≡ › 设置 › 账号与存储 › 存储空间『管理』」→ 缓存、聊天记录；企业微信「左上角『企业微信』› 设置 › 存储管理 › 前往清理」→ 聊天中的文件、缓存。路径用 `FlowLayout` 按步骤换行（窄窗口不许把一步拆开）
- 左栏位置**点击只切换、不扫描**：显示该位置上次结果（每个位置单独存 `results/<base64>.json`），旁边写「N 分钟前 / 昨天 / 未扫描」；没扫过显示「开始扫描」页；扫描只由右上「重新扫描」/「开始扫描」触发
- 记忆：选过的文件夹固定在左栏（UserDefaults `savedFolders`）；启动回到上次看的位置（`lastScope`）；上次看的分类 `lastFilter`；同范围上次检查项数用来估扫描进度
- 权限：用 `~/Library/Safari` 可读判断「完全磁盘访问」；未开启时左栏下方引导去开
- 微信超过 2 GB 时分类卡数字变琥珀；不单独出微信提醒条
- 列表同名项（如几百个 __pycache__）合并成一行「N 处」，点行全选、⌄ 展开
- 磁盘剩余 < 10 GB（`MainView.lowSpaceBytes`）才变琥珀并提示「剩余空间较少」；10 GB 以上不提示（用户明确：别说「空间不足」，别按百分比判断）
- 门槛：工程/应用数据 < 200 MB、「需要判断」< 50 MB 不列；嵌套 node_modules 只列最外层；扫描页「边扫边发现」只显示 ≥ 5 MB

## 验证方法（不抢用户鼠标）

- 截图只截本 App 窗口：按 PID 取最大窗口 ID → `screencapture -l <id>`（不受其他窗口遮挡）
- 切分类：`defaults write io.github.chenmozhe008.qingo lastFilter "<分类名>"` 后重开 App；**不要用模拟鼠标点击**，用户可能在用电脑（2026-10-20 点到过微信）
- 启动参数：`open -g "dist/小清.app" --args --scan`（启动即重新扫描）、`--show-about` / `--show-about=反馈`（直接打开「关于」某一页）、`--tool=uninstall`（可加 `--select-app=<App 名>` 或 `--orphans`）/ `--tool=dev`（可加 `--dev-scan`）直接打开工具页；`--window-size=960x640` 启动时把窗口设成指定大小（截窄窗口用，不依赖辅助功能权限）；`--switch-appearance=自动|浅色|深色` 启动 3 秒后切换外观（验证切换，和点按钮走同一条路）；`--snapshot=<file.png>` 启动 5 秒后把窗口自己画成 PNG（**屏幕锁着时 screencapture 只出黑图，用这个验版面**；玻璃卡片画不出来、带动画的页面可能缺块，只看布局）；`--category=<分类 rawValue>`（如 `大文件与工程`、`剪辑与设计软件`）直接打开分类页；`--creative-app=<工具 id>`（如 workbuddy）打开创作工具页时滚到该工具
- 关于页下方内容（对比表）滚不到：临时把 `comparisonTable` 挪到 intro 顶部截图，截完还原

## 图标

- `Resources/AppIcon-source.png` 必须是**满版不透明正方形**（1024，无透明圆角）。macOS 26+ 会自动套圆角；带透明边的老式图标会被塞进灰色方框
- `Resources/AppIcon-artwork-transparent.png` 是原始带透明边的稿，只作素材留底
- 不要在代码里设置 `NSApplication.applicationIconImage`：会绕过系统圆角，Dock 显示成生硬方块
- 换图标后跑 `script/build_icon.sh`（打包脚本会在源图更新时自动跑）

## 最高原则：只列能放心删的，不让用户判断（2026-10-25 用户定，覆盖下方「清理三档」）

> 用户原话：「大部分人并不具备确认功能，你通过你的逻辑确认好就行了……别让我判断，别让用户判断。」

- 界面上出现的每一项（大文件与工程除外），都是小清已经确认过、删了不丢东西的（会自动重新生成）。**默认全部选好，一个按钮清理**
- 拿不准的（对话记录、作品、模型、依赖、虚拟环境、大文件、工程、离线缓存……）**不列出、不让选、不写「里面有什么 / 本地数据」**；卡片上最多一句「另有 X 是对话和作品，不会动」
- **唯一例外：「大文件与工程」**（用户随后改口：「把东西都列出来，删不删、怎么删我自己决定」）——照 1.2.0 的逻辑：完整扫描列出 ~/Library 外的大文件、安装包、工程；大文件和安装包可勾选（琥珀色，不进一键清理，确认弹窗要勾「我已确认」），工程只列不删
- 已取消：「需要判断」分类、创作工具页的只读行和模型行、开发工程的 node_modules/虚拟环境、「只选可再生缓存」按钮
- Codex 的对话和生成的图片不显示（用户定：对话记录不算可放心删）；`~/.codex` 整个保持保护
- 卸载 App 时连它的工具数据（对话、模型、设置）一起删，默认全选；「已删除应用的残留」规则已经很严，默认全选
- **一键清理，软件开着也照清**（2026-10-25 用户：「我清垃圾就是要快，让我一个个关软件不符合清垃圾的逻辑」）：缓存（`kind == .cache && canTrash`）不做占用检查、不要求退出软件——缓存删了软件会重建，不丢东西；占用检查（lsof）只留给大文件。只有缓存时点「清理」直接清、不弹确认框（进废纸篓 + 结果条「撤销」已经兜底）；选了大文件才弹确认。清完结果条一句话提开着的软件「重开一次才完全腾出」。**别再做「先退出这些软件」的列表或按钮**（做过，被否）
- **不到 1 MB 的缓存不列也不清**（`ScanStore.minShownBytes`，用户嫌 279 KB 的 AE 日志单独占一张卡）；测试里的小样本要先设 `store.minShownBytes = 0`
- 同一家的软件合成一张卡：`CreativeApp.family`（目前 Adobe 全家），卡里每行带 App 简称；卡片按可清理大小从大到小排

## 清理三档（2026-10-24 定，已被上方最高原则取代：第二档不再出现在界面上，代码里的 `decisionNote` 只剩 TrashService 兜底和卸载残留用）

用户反馈「有些垃圾只能查看位置、不能勾选」，从「能清 / 不能清」改成三档：

1. **直接清理**（`kind == .cache && canTrash`）：可重新生成的缓存，进「全选」「只选可再生」。新增 Rust `target`（旁边有 Cargo.toml）、Xcode `DerivedData`（`Library/Developer/Xcode` 里只放开这一个子目录，Archives 等仍保护）
2. **确认后可删**（`SafetyPolicy.decisionNote(for:)` 非 nil；`canTrash` 仍为 false）：`node_modules`、Python 虚拟环境（`.venv`/`venv`，含 pyvenv.cfg）、~/Library 外的大文件和安装包、Hugging Face（`hub/models--*`）和 LM Studio（`models/<作者>/<模型>`）的单个模型。可以勾，但**默认不勾、不进全选**；勾选框和选中色用琥珀色；确认弹窗逐条写「删了会怎样」，勾上「我已确认」才能删；同样只进废纸篓。行副标题带「N 个月没动过」（`ScanItem.modified`，取条目自身 mtime）
3. **只能在原软件处理**：微信、工具的对话/工作区/扩展、工程文件（.fcpbundle/.aep 等，**不进第二档**，是作品）、Figma 离线数据、达芬奇/Final Cut 渲染缓存、Ollama 模型（blob 共享，要用 `ollama rm`）。创作工具页的按钮是「在 XX 里处理」（打开该软件），没装 App 的命令行工具才是「查看位置」

`TrashService` 只认这两档，其余一律拒绝；第二档允许普通文件（大文件），检查是否占用时文件用 `lsof <path>`、目录用 `lsof +D`。

## 清理完成后（2026-10-24 用户反馈「清理完自动扫描体验不好」）

- **清理完不重新扫描**：已移走的条目直接从结果里去掉，统计跟着减，结果存回本地；停在原分类不动
- 没清掉的留在列表里，行内用琥珀色写原因（`ScanStore.failureReasons`），退出相关应用后可直接再清
- 结果条提供「撤销」（按 `trashItem` 返回的位置挪回原处，原位置已有新文件就跳过）和「打开废纸篓」，并写明清空废纸篓后才腾出空间；撤销记录在重新扫描/切换位置后作废
- 重新扫描后保持当前分类，不再跳到第一个有内容的分类

## 工具：卸载应用 / 开发工程（2026-10-24 用户定，效果图 `output/mockups/i-uninstall.png`、`i-dev.png`）

左栏「扫描位置」下方「工具」分组两项（图标和分类一样用彩色 `IconTile`：卸载=橙色垃圾桶，开发=靛蓝 </>），各自独立页面和扫描，不进总览 3×2 卡片、不动分类（`ScanStore.tool`，非 nil 时右侧显示工具页；点位置/分类/总览回到扫描结果）。

**卸载应用**（`AppUninstaller.swift`）
- 列 /Applications、~/Applications（含下一层子文件夹）里的 App；**一个子文件夹里有多个 App 的算一个软件**（如 /Applications/DaVinci Resolve 里主程序、卸载程序、工具共 5 个，用户嫌拆开列），用主程序的名字和图标，卸载时整个文件夹进废纸篓，残留按所有成员的 bundle id 找（`InstalledApp.mainApp` / `memberIDs`）；排除 `com.apple.*`、小清自己、**纯后台辅助程序**（`LSBackgroundOnly`，如用户录音工作台的 RecordingInboxHelper：没有界面、靠它持有权限，误卸会让自动化静默失效；2026-10-25 用户问「这是个啥」）。菜单栏 App（`LSUIElement`）照常列出。左列表按大小 / 按多久没用（Spotlight `kMDItemLastUsedDate`），搜索；右侧是选中 App 的全部痕迹
- 痕迹只在 ~/Library 的固定子目录按 bundle id / App 名精确找：Application Support、Caches、Preferences（`<id>.plist` 和 `<id>.*.plist`）、Saved Application State、HTTPStorages、WebKit、Cookies、Logs、LaunchAgents（文件名以 id 开头或 plist 里指向该 App）。默认全勾（**偏好设置也勾**，用户定）；`CreativeApp` 认识的工具，其 Application Support 目录和 `roots` 算「工具数据」**默认不勾**
- Containers / Group Containers 不读不删（读会弹授权），存在就提示去访达手动删；`SafetyPolicy.isProtected` 的路径跳过
- 正在运行的 App 不让卸载；App 本身用 `NSWorkspace.recycle`（root 所有的 App 系统会要密码），其余用 `trashItem`，删前核对身份和占用；全部进废纸篓，可撤销
- 打开即显示上次的列表和大小（`results/apps.json`），后台 4 个一组静默重量，不清空、不逐行转圈；选中还没量过的 App 立刻单独量（用户嫌「一打开就像在扫描」）
- 详情页三行：App 本身 / 「相关文件」（所有小残留合一行，默认勾，箭头展开）/ 「工具数据」（合一行，琥珀，默认不勾）——用户嫌一堆 KB 级小行
- 「已删除应用的残留」：上述目录里 bundle id 形状（≥3 段、非 com.apple./group.）、且**没有任何已装 App 同厂商前缀（前两段）**、LaunchServices 也找不到的条目，按 id 合并成一行；算第二档，默认不勾、确认后删

**开发工程**（`DevProjects.swift`）
- 默认扫 ~/Coding（`devRoot`，可「更换文件夹…」，用户定只看这一个）；工程＝含 package.json / Cargo.toml / Package.swift / pyproject.toml / requirements.txt / go.mod / build.gradle / Podfile / pubspec.yaml / .git 的目录，产物归到离扫描根最近的那个工程（monorepo 合成一张卡）
- **「全选」只选第一档（构建缓存）**；`node_modules`/虚拟环境只能单独勾，提示写明「定时自动运行的工程会停」（用户：非开发者也要用，必须确定能清；本机 a-stock 早报每天靠 `.venv` 跑）。不再有「选中这 N 个工程」
- 产物沿用 `SafetyPolicy`：构建缓存是第一档（新增 `.turbo`、`.parcel-cache`、`.nuxt`、`.svelte-kit`、`.ruff_cache`、旁边有 build.gradle 的 `.gradle`），`node_modules` / 虚拟环境是第二档；代码不碰
- 「多久没动」＝工程里产物和 .git 以外文件的最新修改时间；筛选「全部（默认）/ 3 个月以上 / 半年以上」；后两档才有「选中这 N 个工程」（只选该筛选下的产物）；工程产物合计 < 20 MB 不列；结果存 `results/dev.json`

## 清理结果提示

- 清理结果走 `CleanupReport`（结构化），不要把系统报错原文拼进 `message`
- 无法移动的目录（root 所有、系统保护）在扫描阶段就排除，不进可清理列表
