# 小清 Qingo（原名 Mac 清理管家 / MacSpaceKeeper）

原生 SwiftUI 磁盘扫描/缓存清理 App。功能说明看 README.md。

- 名字（2026-10-21 用户定）：中文「小清」、英文「Qingo」；**出现名字的地方都要带「Mac 清理工具」**（侧栏、欢迎页、关于、README、仓库简介），光写「小清」别人不知道是干嘛的；名字里不带 Mac（以后可能做 Windows）。**图标（2026-10-29 用户定稿）**：天青渐变底＋白色规整「Q」，Q 的撇是三道流线（圆头等粗、尾部收尖），右上角一颗四角星；风格参照闪电全能下载的图标（渐变圆角底＋顶部光＋白色符号＋软投影），符号约占底板 75%。源文件 `output/mockups/qingo-icon-v6/icons.py`（定稿是 `d`，`d-full.png`＝满版源图），改图标改这个脚本再导出。星放在右上是为了跟左边的圆环配平（用户嫌居左）。历次被否：v1 蓝紫 Q／水滴脸／刻度表盘、v2 天青釉「清」、v3 3D 光泽、v4 粗糙的 Q＋风、v5 水滴 Q（像定位针）／玻璃 Q（像放大镜）／毛笔圆相
- 身份：Swift 模块/可执行文件 `Qingo`，bundle id `io.github.chenmozhe008.qingo`；旧身份 `com.forwardyan.MacSpaceKeeper` 的设置和 `Application Support/MacSpaceKeeper/results` 由 `LegacyMigration` 带过来，别删
- 分发：走 GitHub Releases（以后再做公证），**不上 Mac App Store**（沙盒读不了 ~/Library 和其他应用目录，核心功能会废）

## 版本与发布

- 版本号写在 `script/build_and_run.sh` 的 `APP_VERSION`，构建号取 git 提交数；改版本时同步在 `CHANGELOG.md` 顶部加一节（App「关于」页直接读这个文件，别另写一份）
- 作者 @沉默者之二、反馈邮箱在 `AboutView.swift` 的 `AppInfo`；「关于」三页（介绍 / 更新记录 / 反馈）。标题区＝App 图标 +「小清 Qingo」+ 版本作者 + GitHub 按钮；介绍卡里有醒目的「代码完全开源」卡片；介绍页顺序：介绍卡（标题「AI 时代的 Mac 清理工具」无句号 + 一段说明，不以具体工具名开头）→ 优势（三张卡）→ 对比与说明。定位（2026-10-21 用户定）：**AI 时代的清理工具**，AI Coding 是主卖点、影视创作是加分（只是排序，界面上不写「加分项」）；措辞用「AI Coding」不用「AI 编程」；不写具体识别了多少款（写「主流工具」）；不对竞品下没查证的断言；正文字号不小于 13；竞品对比数据在 `Comparison`（2026-10-21 查官网与评测，查不到的格子写「—」，别凭印象补；界面上不写这类内部说明）
- 左栏扫描位置叫「快速扫描 / 完整扫描」（2026-10-21 定，别再叫「常见缓存 / 我的文件」）
- 外观三选一（`AppearanceMode`，rawValue「跟随系统」存在 defaults 里别改）。**只走 AppKit（`NSApp.appearance` + 清掉各窗口的 appearance），不用 SwiftUI `preferredColorScheme`**。「自动」直接跟随 macOS 外观设置，包括系统自动切换；不再自行按时段强制切换。侧栏开关写字「自动 / 浅色 / 深色」。**分段控件的选中项用 `Theme.raised`（比底槽浅、带阴影）**；GitHub 用 `GitHubMark`；颜色用 `Theme` 的 adaptive 色和 `Theme.fill()`，彩色底上的白字除外。
- 导航（2026-10-28 改）：**总览＝整台 Mac**（左栏顶部常驻，没扫过的位置也能点回来，`ScanStore.goToOverview` 会退回快速扫描结果）；**点扫描位置＝该次扫描自己的明细页**（`showingScanDetail`，按分类列出各类最大的几项，快速扫描页注明不含大文件）。用户反馈过「总览和快速扫描没区别」「快速和完整点了没区别」，别再让位置落到总览上。子页（创作工具/微信）左上大号「‹ 返回总览」；再点当前位置也回总览；「关于与反馈」只在左栏底部一处
- 视觉：macOS 26+ 卡片走原生 `glassEffect`（液态玻璃），窗口透明 + 背后模糊；更早系统回落磨砂（`Theme.glass`）。**别把 `glass()` 换成不透明色块、别把 `Backdrop` 底色调到不透明**（1.0.4 中途被改成 97% 不透明，玻璃效果全没了，用户点名）
- 总览底部六张卡（2026-10-28，用户嫌信息多「看着眼懵」）：**一张卡只有一行：图标＋名称＋一个数**，不写说明小字；没有内容时写「无需清理 / 未扫描」等灰字，不用「—」；顺序：缓存、创作、微信、大文件（取上次完整扫描，`largeFileSummary`）、开发缓存（`DevSummaryTile`）、卸载应用（「N 个长期未使用」，读上次列表不重新测量）。图块里的 SF Symbol 一律缩放进同一个框（`IconTile`），否则大小看着不统一（用户点名）
- 总览（2026-10-25 定稿方案 D「先说结果」，效果图 `output/mockups/k-d-outcome.png`；按苹果原则：内容优先、一眼看懂、先说结果、主操作就在眼前、渐进展开）：`showingOverview` 独立页 = 左侧 `SpaceRing` + 右侧「可清理缓存」小标题／大号数字（`BigBytes`）／「N 项，均可自动重建」+ 胶囊主按钮「清理 X」（`HeroButtonStyle`）+「查看全部 N 项 ›」；没有可清理项时右侧只写「暂无可清理的缓存」，不显示「0 B」；底部六张一行卡（见上条）。分类页只有标题和列表，不再重复统计卡
- 空间圆环 `SpaceRing`（2026-10-25 用户看图选方案 ①，效果图 `output/mockups/m-overview-1-ring.png`）：一整圈粗圆环，有色弧＝已用、缺口＝可用，够用蓝色、< 10 GB 橙色；中间「现在可用 / X / 共 Y」。**只回答「还剩多少」**，「被谁占了」交给底部的卡片，所以不要图例。**不许写「清理后 X」**——清理只是进废纸篓，清空前空间不变（用户指出过这是错的）。之前的分色刻度表盘被否：要配图例才看得懂
- 所有页面同一套页头 `PageHeader`：彩色图块 + 页面名 + 一句「这里是什么、会怎样」+ 右侧主按钮（胶囊 `HeroButtonStyle`）。主按钮不放底部工具条（底部工具条已删）；**分类页的清理按钮只清本页勾选**（`ScanStore.reviewCleanup(scope:)`），总览的按钮清全部。扫描中用同款圆环转圈（两层：粗弧＋反向转的细弧，快速/完整扫描和开发缓存同一结构，2026-10-29 统一）；欢迎页、未扫描页、确认弹窗也用胶囊主按钮
- **配色（2026-10-25 用户嫌蓝紫渐变「挺大众」，要 App Store 头部应用那种美学）**：一个标志色「天青」（取「小清」的清，宋瓷天青釉），按钮、圆环、链接、选中都用它；背景是安静的暖白（深色是石墨灰），左上角带一点天青的光；分类色低饱和成套：缓存天青、创作珊瑚、微信竹青、大文件藕紫、卸载赭橙、开发黛蓝。`Theme.blue` 这个名字保留，值已是天青。App 图标也是天青（2026-10-29 换）
- 背景随空间状态变：剩余 ≥ 10 GB 是上面的安静底色，< 10 GB 变暖（`Backdrop(warm:)`）
- **侧栏在最小窗口里要一屏放下全部分类**（2026-10-28 用户以为「点工具后分类不显示了」，其实是侧栏太高、分类被挤到下面，滚动条又隐藏）：完全磁盘访问已开启时不显示那一行（只在未开启时出引导卡）；底部「关于」和外观切换合成一行；行距 4.5、分组标题间距 4。侧栏加东西前先算高度
- **最小窗口（960×640）下不许挤坏**：胶囊主按钮永不折行（`HeroButtonStyle` 自带 lineLimit+fixedSize）；总览窄时圆环缩小、按钮和「查看」上下排、分类卡两行两列；卸载页窄时列表收窄、卸载按钮挪到名字下面；`PageHeader` 放不下时按钮挪到标题下面；扫描页底部三项统计放不下时整排换成竖排（图标在上，名称、数值各一行，2026-10-28 用户嫌「232. / 4 MB」折行）。改界面必须用 `--window-size=960x640` 截一张验
- 图标：侧栏全部用 SF Symbols 实心彩色图块（`IconTile`）。总览＝仪表、快速扫描＝闪电、完整扫描＝硬盘、文件夹＝文件夹、创作与 AI＝魔棒、微信＝对话气泡、大文件＝文档、卸载＝垃圾桶、开发工程＝锤子；当前扫描位置的图块是蓝色、其余灰色，并加一圈天青描边（`locationRow`）；天青底色（`Theme.selection`，不用灰色 `fill`——用户嫌看不出选中）只给当前页面（总览/分类/工具），描边和底色两种样式，避免两行同时像被选中。「返回总览」用 `ToolbarButtonStyle(tinted:)`，底色 0.18（用户嫌浅）
- 背景 `Backdrop` 是柔和的 MeshGradient 色场（macOS 15+），液态玻璃要有东西可折射才看得出来，别换回纯色
- 子页「返回总览」用标志色 tinted 按钮（`ToolbarButtonStyle(tinted:)`），别做成灰的
- 磁盘可用空间一律**实时读** `volumeAvailableCapacityForImportantUsage`（与访达一致），不用扫描时存下的数
- GitHub **公开仓库**（MIT，2026-10-21 开源）：chenmozhe008/qingo。仓库里不放密钥、个人路径和个人配置；`SafetyPolicy` 的保护名单只写通用目录。README 面向公众，内部约定写本文件
- 文案风格（2026-10-21 定，10-25 两次强调）：**像专业 Mac 软件，不像 AI 聊天**。参照 macOS 和成熟清理工具：短句、中性、陈述事实；用「清理 / 移到废纸篓（Apple 原词，不说"放进"）/ 可自动重建 / 需手动确认 / 仅显示大小 / 未清理 / 正在运行」这类标准说法。**不写**：口语和打包票（一个不碰、放心清、拿不准、删不删由你决定、教你点哪里、这台 Mac 很干净、哗一下）、对用户喊话的「你…」句、第一人称「我」、程序腔（没有项目被移动）。一行只说一件事，不用「·」串信息；失败原因写清是什么情况；显示 App 名不显示文件夹名；竞品只写查证过的事实。CHANGELOG 会显示在「关于 → 更新记录」，按正式更新说明写
- 界面用词表（2026-10-25 用户第三次指出「大文件与工程」「完整扫描才查」不像软件说的话）：「工程」→「项目」（分类名就叫「大文件」，工具叫「开发缓存」（2026-10-28 由「开发项目」改，用户：只清构建缓存，叫项目像要删项目）；`ItemFilter.large` 的 rawValue「大文件与工程」存在 defaults 和 `--category` 里，只改 `title`）；计数一律用「项」，不用「处」；「仅显示占用 / 仅统计」→「仅显示大小」；「久未使用」→「长期未使用」；「不涉及」→「不影响」；「都在 X 里」→「位于 X」；「大约」→「约」；「还没扫描过」→「尚未扫描」；时间写「上次扫描：3 分钟前」。加新文案前先对一遍这张表

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
- 窗口用 `.hiddenTitleBar`，内容顶到标题栏，左上留红绿灯位置
- 场景是单个 `Window`（2026-10-25）：关窗口即退出，点 Dock 图标重新打开。别换回 `WindowGroup` + 删 `.newItem`——那样关窗后进程还在、点图标也叫不出窗口（用户反馈过）
- 列表交互：点行=选中（可清理项），行尾 ⓘ=展开详情；选中行青色底+左侧色条（第二档用琥珀色）；页头「全选 ⌘A」只管第一档
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
- 左栏位置**点击只切换、不扫描**：显示该位置上次结果（每个位置单独存 `results/<base64>.json`），旁边写「N 分钟前 / 昨天 / 未扫描」；没扫过显示「开始扫描」页；扫描只由顶栏「重新扫描」/「开始扫描」触发。「重新扫描」是扫描时间后面的天青按钮（`ToolbarButtonStyle` tinted；结果超过 1 天时时间旁加琥珀色「结果可能已过期」、按钮变实心）。改成纯文字链接被用户否了（「重要功能，太不显眼」）
- 记忆：选过的文件夹固定在左栏（UserDefaults `savedFolders`）；启动回到上次看的位置（`lastScope`）；上次看的分类 `lastFilter`；同范围上次检查项数用来估扫描进度
- 权限：用 `~/Library/Safari` 可读判断「完全磁盘访问」；未开启时左栏下方引导去开
- 微信超过 2 GB 时分类卡数字变琥珀；不单独出微信提醒条
- 列表同名项（如几百个 __pycache__）合并成一行「N 处」，点行全选、⌄ 展开
- 磁盘剩余 < 10 GB（`MainView.lowSpaceBytes`）才变琥珀并提示「剩余空间较少」；10 GB 以上不提示（用户明确：别说「空间不足」，别按百分比判断）
- 门槛：工程/应用数据 < 200 MB、「需要判断」< 50 MB 不列；嵌套 node_modules 只列最外层；扫描页「边扫边发现」只显示 ≥ 5 MB

## 验证方法（不抢用户鼠标）

- 截图只截本 App 窗口：按 PID 取最大窗口 ID → `screencapture -l <id>`（不受其他窗口遮挡）
- 切分类：`defaults write io.github.chenmozhe008.qingo lastFilter "<分类名>"` 后重开 App；**不要用模拟鼠标点击**，用户可能在用电脑（2026-10-20 点到过微信）
- 启动参数：`open -g "dist/小清.app" --args --scan`（启动即重新扫描）、`--show-about` / `--show-about=反馈`（直接打开「关于」某一页）、`--tool=uninstall`（可加 `--select-app=<App 名>` 或 `--orphans`）/ `--tool=dev`（可加 `--dev-scan`）直接打开工具页；`--scan-detail` 打开当前位置的明细页；`--window-size=960x640` 启动时把窗口设成指定大小（截窄窗口用，不依赖辅助功能权限）；`--switch-appearance=自动|浅色|深色` 启动 3 秒后切换外观（验证切换，和点按钮走同一条路）；`--snapshot=<file.png>` 启动 5 秒后把窗口自己画成 PNG（**屏幕锁着时 screencapture 只出黑图，用这个验版面**；玻璃卡片画不出来、带动画的页面可能缺块，只看布局）；`--category=<分类 rawValue>`（如 `大文件与工程`、`剪辑与设计软件`）直接打开分类页；`--creative-app=<工具 id>`（如 workbuddy）打开创作工具页时滚到该工具
- **演示 / 截图用假数据（2026-10-27 做推荐视频时加）**：环境变量 `QINGO_HOME=<文件夹>` 把扫描的个人文件夹换成准备好的演示文件夹（`AppHome.url`）；演示模式下不迁移旧设置、不列外接磁盘、不读本机装了哪些 App（`AppHome.isDemo`），**录屏绝不能露出用户真实的项目名、硬盘名、文件名**（第一次拍就露了移动硬盘名）。配合 `QINGO_RESULTS_DIR` 和改了 bundle id 的副本（`io.github.chenmozhe008.qingo.demo`，设置不碰正式版）。`--quick-scan` 启动即快速扫描；`--clean-after=<秒>` 只在演示模式下生效，到时自动点「清理」（会进真实废纸篓，拍完挪回演示文件夹）。演示文件用 `cp -c` 克隆同一个大文件，显示几十 GB、实际只占约 1.5 GB（小清按已分配空间算，空洞文件显示 0）。演示环境三步：`output/promo/tools/demo_home.sh <目录>` 建假数据 → `mkapp.sh` 打演示版副本 → `session.sh <前缀> "<秒数…>" [启动参数]` 按时间截图（两个脚本开头的 `D=` 改成同一目录，用项目内 `tmp/demo`：**别放 /tmp**，/tmp 和 /private/tmp 两种写法对不上，侧栏「完整扫描」会显示「未扫描」；拍完用 defaults 写 `lastScope` 为演示 home 再 `--scan` 得到完整扫描结果；用完移到废纸篓）。README 截图（`docs/images/`，1920 宽）就用它拍；**界面改版、换图标后都要重拍截图**（2026-10-28 发现 README 还挂着 1.1.0 的旧界面；10-29 换图标后 6 张又重拍）。拍法：先 `session.sh` 跑 `--quick-scan`、写 lastScope 后 `--scan`、`--tool=dev --dev-scan` 预热，再每张单独启动并带 `--switch-appearance=浅色|深色`，2560 宽缩到 1920×1200 放进 `docs/images/`。做视频的脚本和成片在 `output/promo/`（当前源文件 `film-v3/`：`render.js` 渲染画面，`sfx.js` 导出音效时间点，`mix.py` 混人声＋音乐＋音效；配乐和音效只用可商用免署名的，来源和授权写在 `film-v3/audio/music/LICENSE.txt`。`loudnorm` 后必须 `aresample=48000`，否则 `sidechaincompress` 会在人声结束时把音乐截掉——v4 片尾音乐突然没了就是这个原因）
- **宣传视频交付前检查（2026-10-27，v2→v6 反复返工后定）**：抽几张静帧看不出动态问题，每一项都要做完才交给用户
  - 有动作的段落（换场、推镜、浮层、点击）**每 0.25 秒一帧**排成联系表逐帧看：位置有没有漂移或晃动、有没有出画或被裁、两个场景的文字有没有叠在一起、放大后发不发虚（不用 transform 放大位图，用 CSS `zoom` 或直接改尺寸）
  - 不用框套界面元素（用户两次否定）；要让小字看清，用「放大镜」浮层（`#lens`）把那块界面原样放大浮出，窗口本身不动、不出画
  - 声音跑 `qa_audio.py`：关键音效（点击、警告、完成）在触发时刻不能比人声低 8 dB 以上；最后 4 秒不能掉到静音。不能只看整体响度
  - 内容自查：同一画面里的图标不重复（AE 和 Pr 要分开）、字幕和配音逐字一致、用词对一遍上面的界面用词表
  - 把用户之前每一轮的反馈当验收清单逐条对一遍再交付
- **版本号（2026-10-27 用户定：「别的工具每一版都有编号，不能每次都用一个」）**：每次装到用户电脑或发布，都先升版本号（`script/build_and_run.sh` 的 `APP_VERSION`）。修问题、改文字升第三位（1.9.1 → 1.9.2），加功能升第二位（1.9 → 1.10）；CHANGELOG 每个版本单独一节；每个发布版打 `v<版本>` 标签、单独一个 GitHub Release，已发布的版本不改。宣传视频等交付物也按 v1、v2 另存，不覆盖
- **发布**：`./script/package_release.sh` → `tmp/release/Qingo-<版本>.zip`，临时签名（证书名里有个人邮箱，不能用）＋ strip 调试符号（里面有本机路径），脚本发现 `/Users/` 会拒绝打包；上传 GitHub Releases（`gh release create v<版本> … --latest`，说明照上一版的格式：简介 / 下载安装 / 本版更新内容；中间没单独发布的版本，改动并进这一版）。「无法验证开发者」提示去不掉（2026-10-29 用户问过）：要 Apple Developer ID 签名＋公证（开发者账号 99 美元/年），没办就只能在 README 和 Release 里写「隐私与安全性 → 仍要打开」或终端 `xattr -dr com.apple.quarantine /Applications/小清.app`。**2026-10-29 用户定：先不花钱，不办**；以后要办：用户 iPhone「Apple Developer」App 实名申请个人账号 → 生成 Developer ID Application 证书＋App 专用密码 → 改 `package_release.sh`：Developer ID 签名＋hardened runtime → `notarytool submit --wait` → `stapler staple`（本机 notarytool/stapler 在移动硬盘的 Xcode-26.5 里）。代价：证书名是实名，会公开在签名里。换图标后 Dock 还显示旧图：`lsregister -f` 这个 App 再 `killall Dock`
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

1. **直接清理**（`kind == .cache && canTrash`）：可重新生成的缓存，进「全选」。新增 Rust `target`（旁边有 Cargo.toml）、Xcode `DerivedData`（`Library/Developer/Xcode` 里只放开这一个子目录，Archives 等仍保护）
2. **确认后可删**（`SafetyPolicy.decisionNote(for:)` 非 nil；`canTrash` 仍为 false）：`node_modules`、Python 虚拟环境（`.venv`/`venv`，含 pyvenv.cfg）、~/Library 外的大文件和安装包、Hugging Face（`hub/models--*`）和 LM Studio（`models/<作者>/<模型>`）的单个模型。可以勾，但**默认不勾、不进全选**；勾选框和选中色用琥珀色；确认弹窗逐条写「删了会怎样」，勾上「我已确认」才能删；同样只进废纸篓。行副标题带「N 个月没动过」（`ScanItem.modified`，取条目自身 mtime）
3. **只能在原软件处理**：微信、工具的对话/工作区/扩展、工程文件（.fcpbundle/.aep 等，**不进第二档**，是作品）、Figma 离线数据、达芬奇/Final Cut 渲染缓存、Ollama 模型（blob 共享，要用 `ollama rm`）。创作工具页的按钮是「在 XX 里处理」（打开该软件），没装 App 的命令行工具才是「查看位置」

`TrashService` 只认这两档，其余一律拒绝；第二档允许普通文件（大文件），检查是否占用时文件用 `lsof <path>`、目录用 `lsof +D`。

## 清理完成后（2026-10-24 用户反馈「清理完自动扫描体验不好」）

- **旧结果不当真**（2026-10-25 用户点了 5 天前的完整扫描，清理后大部分「未清理」、2 GB 不变）：打开保存的结果时先去掉磁盘上已不存在的条目（`showSavedResult`）；清理时缓存被软件重建过（同路径、新 inode）照样清，按实际大小算；已不存在的从列表去掉，不算失败（`TrashError.gone` → `CleanupOutcome.gone`）。身份必须一致只对需手动确认的大文件
- 结果条的「未清理」直接按原因分行列出（「N 处未清理：原因　A、B 等」），不用折叠的「查看原因」（用户：不明显，点了像没反应）
- **清理完不重新扫描**：已移走的条目直接从结果里去掉，统计跟着减，结果存回本地；停在原分类不动
- 没清掉的留在列表里，行内用琥珀色写原因（`ScanStore.failureReasons`），退出相关应用后可直接再清
- 结果条提供「撤销」（按 `trashItem` 返回的位置挪回原处，原位置已有新文件就跳过）和「打开废纸篓」，并写明清空废纸篓后才腾出空间；结果条 15 秒后自动收起，文件仍可在废纸篓中放回。撤销记录在重新扫描/切换位置后作废。
- 重新扫描后保持当前分类，不再跳到第一个有内容的分类

## 工具：卸载应用 / 开发工程（2026-10-24 用户定，效果图 `output/mockups/i-uninstall.png`、`i-dev.png`）

左栏「扫描位置」下方「工具」分组两项（开发缓存在上、卸载应用在下；彩色 `IconTile`：开发=靛蓝锤子，卸载=橙色垃圾桶），各自独立页面和扫描，总览各有一张摘要卡但不并入一键清理、不动分类（`ScanStore.tool`，非 nil 时右侧显示工具页；点位置/分类/总览回到扫描结果）。

**卸载应用**（`AppUninstaller.swift`）
- 「已删除应用的残留」是列表上方单独一张小卡（之前钉在列表底部，会切掉最后一行，用户嫌乱）
- 列 /Applications、~/Applications（含下一层子文件夹）里的 App；**一个子文件夹里有多个 App 的算一个软件**（如 /Applications/DaVinci Resolve 里主程序、卸载程序、工具共 5 个，用户嫌拆开列），用主程序的名字和图标，卸载时整个文件夹进废纸篓，残留按所有成员的 bundle id 找（`InstalledApp.mainApp` / `memberIDs`）；排除 `com.apple.*`、小清自己、**纯后台辅助程序**（`LSBackgroundOnly`，如用户录音工作台的 RecordingInboxHelper：没有界面、靠它持有权限，误卸会让自动化静默失效；2026-10-25 用户问「这是个啥」）。菜单栏 App（`LSUIElement`）照常列出。左列表按大小 / 按多久没用（Spotlight `kMDItemLastUsedDate`），搜索；右侧是选中 App 的全部痕迹
- 痕迹只在 ~/Library 的固定子目录按 bundle id / App 名精确找：Application Support、Caches、Preferences（`<id>.plist` 和 `<id>.*.plist`）、Saved Application State、HTTPStorages、WebKit、Cookies、Logs、LaunchAgents（文件名以 id 开头或 plist 里指向该 App）。默认全勾（**偏好设置也勾**，用户定）；`CreativeApp` 认识的工具，其 Application Support 目录和 `roots` 算「工具数据」**默认不勾**
- Containers / Group Containers 不读不删（读会弹授权），存在就提示去访达手动删；`SafetyPolicy.isProtected` 的路径跳过
- 正在运行的 App 不让卸载；App 本身用 `NSWorkspace.recycle`（root 所有的 App 系统会要密码），其余用 `trashItem`，删前核对身份和占用；全部进废纸篓，可撤销
- 打开即显示上次的列表和大小（`results/apps.json`），后台 4 个一组静默重量，不清空、不逐行转圈；选中还没量过的 App 立刻单独量（用户嫌「一打开就像在扫描」）
- 详情页三行：App 本身 / 「相关文件」（所有小残留合一行，默认勾，箭头展开）/ 「工具数据」（合一行，琥珀，默认不勾）——用户嫌一堆 KB 级小行
- 「已删除应用的残留」：上述目录里 bundle id 形状（≥3 段、非 com.apple./group.）、且**没有任何已装 App 同厂商前缀（前两段）**、LaunchServices 也找不到的条目，按 id 合并成一行；算第二档，默认不勾、确认后删

**开发工程**（`DevProjects.swift`）
- 快速扫描时后台检查代码文件夹（`DevStore.discoverIfNeeded`），结果只进总览的「开发缓存」卡，不并入一键清理；有待处理选择、确认、清理或撤销记录时不自动重扫
- 扫描页和主扫描同一结构（用户嫌只有一个小圆圈「太简单」）：左侧双层转环＋已检查数＋当前位置＋进度条（按上次同目录检查数估算，`devScanSize:<路径>`），右侧「已发现的项目」实时列表（`DevScanner.scan(onFound:)`）＋项目数 / 构建缓存合计
- 默认扫 ~/Coding（`devRoot`，可「更换文件夹…」，用户定只看这一个）；工程＝含 package.json / Cargo.toml / Package.swift / pyproject.toml / requirements.txt / go.mod / build.gradle / Podfile / pubspec.yaml / .git 的目录，产物归到离扫描根最近的那个工程（monorepo 合成一张卡）
- 只列构建缓存，默认全选；`node_modules`/虚拟环境不列（用户：非开发者也要用，必须确定能清；本机 a-stock 早报每天靠 `.venv` 跑；1.5 前的旧结果载入时过滤掉）
- 产物沿用 `SafetyPolicy`：构建缓存是第一档（新增 `.turbo`、`.parcel-cache`、`.nuxt`、`.svelte-kit`、`.ruff_cache`、旁边有 build.gradle 的 `.gradle`），`node_modules` / 虚拟环境是第二档；代码不碰
- 项目按「多久没动」排序（产物和 .git 以外文件的最新修改时间，最久的在前）；项目产物合计 < 5 MB 不列（`DevScanner.minProjectBytes`）；结果存 `results/dev.json`

## 剩余空间提醒（2026-10-29 用户要：「没打开小清时，空间低了也弹提醒，一点就开始快速扫描」）

- 取代作者本机原来的 shell 定时监测（一天一次、点通知只会打开脚本编辑器）。那个任务已停用，恢复方法记在作者本地，不进仓库
- 检查间隔 30 分钟（2026-10-29 用户同意）：检查只读一次剩余空间、几毫秒，间隔只影响多快发现；打扰次数由下面的去重规则管，别为了「少打扰」把间隔拉长
- 结构（`SpaceAlert.swift`）：包内后台任务 `Contents/Library/LaunchAgents/io.github.chenmozhe008.qingo.space-check.plist`（打包脚本生成，`BundleProgram` 指向本包），由 `SMAppService.agent` 注册；每 30 分钟和登录时跑 `Qingo --check-space`：不起界面，读 `volumeAvailableCapacityForImportantUsage`，发完通知就退出（`QingoApp.init` 里最先判断，早于迁移和界面）
- 阈值就是 `MainView.lowSpaceBytes`（10 GB），**不另设可调阈值**，界面变琥珀和发通知同一个口径
- 什么时候提醒（`SpaceAlert.shouldWarn`）：刚低于阈值提醒一次；之后满 24 小时、或又少了 5 GB 再提醒；回到阈值 +1 GB 以上算恢复，下次低了重新提醒。通知 id 固定，通知中心里不会堆一串
- 文案：标题「剩余空间较少」（用户定过别说「空间不足」），正文「可用 X。点按以开始快速扫描。」
- 点通知：`AppDelegate` 收到 → `ScanStore.quickScanFromAlert()`（关掉工具页和关于，开始快速扫描；正在扫描或清理就只把窗口叫到前面）。App 还没建好 store 时先记 `SpaceAlert.openPending`
- 开关：菜单「小清 › 剩余空间较少时提醒」，默认开；首次启动会弹系统通知授权。用户手动打开时如果通知被拒，跳系统设置的通知页。演示模式（`QINGO_HOME`）不注册、不弹授权
- **实测（2026-10-29）**：App 必须在 `/Applications` 或 `~/Applications` 这类正常位置，放在项目 `tmp/` 里系统直接拒通知权限；开发证书签名下通知、注册、点击回调都通。验证后台任务：`launchctl print gui/$(id -u)/io.github.chenmozhe008.qingo.space-check`；验证通知：`QINGO_PRETEND_FREE=8000000000 ~/Applications/小清.app/Contents/MacOS/Qingo --check-space`（假装只剩 8 GB；发过一次后 24 小时内不再发，重测先 `defaults delete io.github.chenmozhe008.qingo spaceAlertLastDate`）。这个模式会打印通知授权状态：`authorization: 1` 是被拒（通知发了但不显示，10-29 测试时就是授权框被点了「不允许」），去系统设置 › 通知 › 小清打开

## 空间变化报告（2026-10-29 用户看效果图 `output/mockups/r-growth/` 后定：A 卡片 + 点进去是 B 的完整页）

- 用户原话：「突然间哪一块集聚的占空间，你会有个分析，哪个软件、什么原因导致的」
- 总览：`SpaceGrowth.isNotable`（增长项合计 ≥ 1 GB 或可用空间少了 ≥ 5 GB）时，在清理按钮下面出一张卡：标题「N 天内可用空间减少 X」+ 增长最多的 3 项（最小窗口 2 项）+「查看报告 ›」。只在显示快速扫描结果时有
- 报告页（`store.showingGrowth`，子页带「返回总览」，**左栏不加行**：左栏高度是卡死的）：页头 + 可用空间曲线卡 + 全部增长项（≥ 200 MB）+「其他位置」（可用空间减少量 − 所有项增长之和，≥ 1 GB 才列，按钮去完整扫描）
- 每行：名称、说明取 `note` 第一句、增长量（琥珀）、「共 X」；能清的「清理」（`reviewCleanup(only:)`，只清这一项，**清的是整项不只是增长部分**）、只读数据写「仅显示大小」、微信「查看方法」
- 对比基准：`results/quick-baseline`。新快速扫描覆盖旧结果前，旧结果满 12 小时才替换基准（`SpaceGrowth.nextBaseline`），否则几分钟前扫过一次就什么都对比不出来。清理后存回结果不动基准
- 口径：两边都有 `availableBytes`（访达同款，1.12 起扫描时记录）就用它，否则都用 `volumeFreeBytes`，**不混用**
- 曲线：后台检查每 30 分钟往 `results/space-history.json` 记一次（留 14 天），记录不满两点时显示一句说明。通知正文在 3 天内少了 ≥ 2 GB 时带上「N 天内减少 X」
- 验证：拷一份 results 到项目 `tmp/`，造一个 3 天前的 `cXVpY2stYmFzZWxpbmU=.json`（"quick-baseline" 的 base64）和 history，`open -n -g --env QINGO_RESULTS_DIR=<目录> dist/小清.app --args --growth --snapshot=…`；**要用 open 起 App**，直接跑可执行文件没有完全磁盘访问权限，截出来不准

## 检查更新（2026-10-29 用户定：「肯定要做，改承诺就行」）

- 小清唯一联网的地方：`UpdateChecker` 每天最多一次读 GitHub `releases/latest` 的版本号（`updateLastCheck` 记时间，一天内用缓存的结果），不上传任何东西。README 的承诺已改成「仅在检查更新时访问 GitHub（每天最多一次，可关闭）」，**别再写「不联网」**
- 有新版：顶栏最右边一个 tinted 按钮「新版本 X」，点了打开 Release 页下载。**不放侧栏**：试过放「关于」上方，最小窗口把「大文件」挤掉一半（左栏高度规则）
- 菜单「小清 › 检查更新…」（弹窗说结果）、「自动检查更新」开关（默认开）。不做自动安装：没公证，自己替换自己会被 Gatekeeper 拦
- 版本比较按数字逐段（1.10 > 1.9），开发版不提示；**发 Release 时 tag 必须是 `v<版本>`**，否则比较不出来
- 验证：`open -n -g --env QINGO_PRETEND_UPDATE=9.9.9 dist/小清.app --args --snapshot=…` 假装有新版

## 清理结果提示

- 清理结果走 `CleanupReport`（结构化），不要把系统报错原文拼进 `message`
- 无法移动的目录（root 所有、系统保护）在扫描阶段就排除，不进可清理列表
