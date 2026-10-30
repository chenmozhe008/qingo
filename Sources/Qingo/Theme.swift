import AppKit
import SwiftUI

extension Color {
    /// Resolves per appearance, so one palette serves light and dark mode.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Brand palette (mockup B, 2026-10-20), with a light variant (2026-10-21).
enum Theme {
    static let base = Color.adaptive(light: rgb(0.96, 0.97, 0.99), dark: rgb(0.065, 0.08, 0.12))
    // Palette (2026-10-25): one brand colour, 天青 (celadon, the 清 in 小清), on a quiet warm-neutral field; category
    // colours are a muted, harmonious set. Names are kept from the old palette: `blue` is the brand colour now.
    static let ink = Color.adaptive(light: rgb(0.12, 0.13, 0.13), dark: rgb(0.92, 0.94, 0.93))
    static let ink2 = Color.adaptive(light: rgb(0.36, 0.38, 0.38), dark: rgb(0.66, 0.70, 0.69))
    static let ink3 = Color.adaptive(light: rgb(0.47, 0.50, 0.50), dark: rgb(0.56, 0.60, 0.59))
    /// Brighter secondary text used on brand-tinted surfaces.
    static let softInk = Color.adaptive(light: rgb(0.06, 0.40, 0.38), dark: rgb(0.70, 0.92, 0.88))
    static let line = Color.adaptive(light: rgb(0, 0, 0, 0.08), dark: rgb(1, 1, 1, 0.08))
    static let panel = Color.adaptive(light: rgb(1, 1, 1, 0.94), dark: rgb(0.12, 0.14, 0.14, 0.96))
    /// The chosen segment of a segmented control: lighter than its track in both modes, never darker.
    static let raised = Color.adaptive(light: rgb(1, 1, 1), dark: rgb(0.30, 0.32, 0.33))
    static let usedTint = Color.adaptive(light: rgb(0.55, 0.72, 0.70), dark: rgb(0.32, 0.50, 0.48))
    static let track = Color.adaptive(light: rgb(0.80, 0.81, 0.80), dark: rgb(0.30, 0.34, 0.34))
    /// Brand colour, 天青.
    static let blue = Color.adaptive(light: rgb(0.09, 0.53, 0.51), dark: rgb(0.38, 0.80, 0.75))
    /// Selected sidebar row: brand-tinted, clearly stronger than hover or the grey fills around it.
    static let selection = Color.adaptive(light: rgb(0.09, 0.53, 0.51).withAlphaComponent(0.16), dark: rgb(0.38, 0.80, 0.75).withAlphaComponent(0.22))
    /// Fill behind white button text: the brand colour, deeper in dark mode so the label stays readable.
    static let blueFill = Color.adaptive(light: rgb(0.09, 0.53, 0.51), dark: rgb(0.12, 0.50, 0.47))
    /// The lighter end of the brand colour; also the "cleanable cache" category.
    static let cyan = Color.adaptive(light: rgb(0.22, 0.65, 0.61), dark: rgb(0.48, 0.86, 0.80))
    /// 黛蓝, developer projects.
    static let indigo = Color.adaptive(light: rgb(0.30, 0.40, 0.68), dark: rgb(0.52, 0.62, 0.90))
    /// 藕紫, large files.
    static let violet = Color.adaptive(light: rgb(0.52, 0.44, 0.74), dark: rgb(0.70, 0.63, 0.90))
    static let amber = Color.adaptive(light: rgb(0.80, 0.52, 0.10), dark: rgb(0.96, 0.72, 0.34))
    /// 赭橙, uninstall.
    static let orange = Color.adaptive(light: rgb(0.86, 0.52, 0.26), dark: rgb(0.95, 0.65, 0.40))
    static let slate = Color.adaptive(light: rgb(0.52, 0.56, 0.56), dark: rgb(0.48, 0.53, 0.53))
    /// 珊瑚, creative and AI tools.
    static let pink = Color.adaptive(light: rgb(0.85, 0.41, 0.34), dark: rgb(0.95, 0.57, 0.48))
    /// 竹青, chat apps.
    static let green = Color.adaptive(light: rgb(0.35, 0.60, 0.37), dark: rgb(0.52, 0.78, 0.52))

    /// Neutral overlay: white on dark, black on light.
    static func fill(_ opacity: Double) -> Color {
        Color.adaptive(light: rgb(0, 0, 0, CGFloat(opacity * 0.75)), dark: rgb(1, 1, 1, CGFloat(opacity)))
    }

    static let accent = LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing)
    static let warning = LinearGradient(colors: [amber, orange], startPoint: .leading, endPoint: .trailing)

    static func symbol(_ category: ItemFilter) -> String {
        switch category {
        case .caches: "sparkles"
        case .creative: "wand.and.stars"
        case .chat: "message.fill"
        case .review: "hand.raised.fill"
        case .large: "doc.on.doc.fill"
        }
    }

    static func color(_ category: ItemFilter) -> Color {
        switch category {
        case .caches: cyan
        case .creative: pink
        case .chat: green
        case .review: amber
        case .large: violet
        }
    }
}

/// Soft colour field behind the glass cards; Liquid Glass needs something to refract, a flat fill looks like plain white panels.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    /// Low on space: the field warms, like Weather's sky follows the weather. Plenty of room stays a calm blue.
    var warm = false

    var body: some View {
        ZStack {
            WindowBlur()
            if #available(macOS 15.0, *) {
                MeshGradient(width: 3, height: 3,
                             points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                             colors: (scheme == .dark ? (warm ? Self.darkWarm : Self.dark) : (warm ? Self.lightWarm : Self.light))
                                .map { Color(red: $0[0], green: $0[1], blue: $0[2]) })
                    .opacity(0.58)
            } else {
                Theme.base.opacity(0.9)
            }
        }
        .ignoresSafeArea()
    }

    // Quiet warm paper with a breath of 天青 at the top left; the dark field is graphite with the same breath.
    private static let light: [[Double]] = [[0.91, 0.96, 0.95], [0.95, 0.96, 0.95], [0.96, 0.96, 0.95],
                                            [0.94, 0.96, 0.95], [0.97, 0.97, 0.96], [0.97, 0.96, 0.94],
                                            [0.95, 0.96, 0.95], [0.97, 0.96, 0.95], [0.97, 0.95, 0.93]]
    private static let lightWarm: [[Double]] = [[1.0, 0.92, 0.84], [0.99, 0.94, 0.89], [0.99, 0.93, 0.88],
                                                [0.99, 0.95, 0.91], [0.99, 0.97, 0.95], [0.99, 0.93, 0.89],
                                                [0.99, 0.93, 0.87], [0.99, 0.95, 0.91], [0.98, 0.91, 0.88]]
    private static let darkWarm: [[Double]] = [[0.20, 0.12, 0.07], [0.15, 0.10, 0.08], [0.13, 0.10, 0.08],
                                               [0.13, 0.09, 0.08], [0.09, 0.08, 0.07], [0.12, 0.09, 0.08],
                                               [0.14, 0.10, 0.07], [0.11, 0.09, 0.08], [0.13, 0.08, 0.08]]
    private static let dark: [[Double]] = [[0.06, 0.13, 0.13], [0.07, 0.09, 0.09], [0.07, 0.08, 0.08],
                                           [0.06, 0.10, 0.10], [0.05, 0.06, 0.06], [0.07, 0.08, 0.08],
                                           [0.06, 0.09, 0.09], [0.06, 0.07, 0.07], [0.08, 0.08, 0.08]]
}

/// Behind-window blur so the window itself reads as glass.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Liquid Glass on macOS 26+; `highlighted` tints the active card blue. Older systems get a frosted panel.
    @ViewBuilder
    func glass(radius: CGFloat = 20, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(highlighted ? .regular.tint(Theme.blue.opacity(0.22)) : .regular, in: shape)
                .overlay(shape.strokeBorder(highlighted ? Theme.blue.opacity(0.45) : .clear, lineWidth: 1).allowsHitTesting(false))
        } else {
            self
                .background(shape.fill(Theme.panel))
                .overlay(shape.fill(highlighted ? Theme.blue.opacity(0.08) : .clear).allowsHitTesting(false))
                .overlay(shape.strokeBorder(highlighted ? Theme.blue.opacity(0.45) : Theme.line, lineWidth: 1))
        }
    }
}

/// Groups glass cards so macOS 26 renders them together; one pass per card made long scrolling pages stutter.
struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(configuration.isPressed ? 0.12 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
    }
}

/// Actions on cleanup results remain distinct from secondary controls.
struct ResultActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.blue.opacity(configuration.isPressed ? 0.23 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.blue.opacity(0.35)))
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.blue.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.blue.opacity(0.4)).frame(height: 1).offset(y: 3)
            }
    }
}

/// Thin capsule bar with a glowing fill.
struct GlowBar: View {
    let fraction: Double
    var fill: LinearGradient = Theme.accent
    var glow: Color = Theme.cyan

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill(0.08))
                Capsule().fill(fill)
                    .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: glow.opacity(0.55), radius: 4)
            }
        }
    }
}

/// Scan progress: filled to the estimate when one exists, otherwise a band sweeping across.
struct ScanProgressBar: View {
    let fraction: Double?
    var fill: LinearGradient = Theme.accent
    var glow: Color = Theme.cyan

    var body: some View {
        if let fraction {
            GlowBar(fraction: fraction, fill: fill, glow: glow)
        } else {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill(0.08))
                        Capsule().fill(fill)
                            .frame(width: proxy.size.width * 0.3)
                            .offset(x: proxy.size.width * (phase * 1.3 - 0.3))
                            .shadow(color: glow.opacity(0.6), radius: 4)
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}

/// Disk usage ring: segments are fractions of total capacity, drawn clockwise from 12 o'clock.
struct UsageRing: View {
    struct Segment {
        let fraction: Double
        let style: AnyShapeStyle
        var glow: Color = .clear
    }

    let segments: [Segment]
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill(0.08), lineWidth: lineWidth)
            ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                Circle()
                    .trim(from: item.start, to: item.end)
                    .stroke(item.segment.style, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .shadow(color: item.segment.glow, radius: 6)
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
    }

    private var placed: [(segment: Segment, start: Double, end: Double)] {
        var start = 0.0
        return segments.compactMap { segment in
            guard segment.fraction > 0 else { return nil }
            // Keep tiny but non-zero categories visible.
            let length = min(max(segment.fraction, 0.012), 1 - start)
            defer { start += length }
            return (segment, start, start + length)
        }
    }
}

/// Top-bar actions: `prominent` is the primary (rescan), otherwise a clear secondary button.
struct ToolbarButtonStyle: ButtonStyle {
    var prominent = false
    var large = false
    /// Blue-tinted secondary, for navigation such as "返回总览".
    var tinted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? Color.white : (tinted ? Theme.blue : Theme.ink))
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 10 : 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(prominent ? Theme.blueFill : (tinted ? Theme.blue.opacity(configuration.isPressed ? 0.28 : 0.18) : Theme.fill(configuration.isPressed ? 0.12 : 0.05))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(prominent ? .clear : (tinted ? Theme.blue.opacity(0.45) : Theme.line)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// System Settings–style rounded icon tile with a white SF Symbol.
/// The app icon at small size, without an extra tile behind it.
struct SidebarBrandMark: View {
    var size: CGFloat = 38
    private static let icon = Bundle.main.url(forResource: "AppIcon-source", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "externaldrive.fill.badge.checkmark").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(Theme.blue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            )
            // Every glyph fitted into the same box: a wide bubble and a thin wand read as the same size.
            .overlay(Image(systemName: symbol).resizable().scaledToFit().fontWeight(.bold).foregroundStyle(.white)
                .frame(width: size * 0.52, height: size * 0.52))
            .frame(width: size, height: size)
    }
}

/// Wraps children onto new lines like text (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], next, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}


/// How much room is left, at a glance: one thick ring like the Activity rings, the coloured arc is what is used
/// and the gap is what is free. Blue while there is room, orange below 10 GB. "Who took the space" is the
/// platters' job, so the ring needs no legend (用户选定方案 ①，2026-10-25).
/// A size as a large rounded figure with a smaller unit beside it: "38.04 GB".
struct BigBytes: View {
    let bytes: Int64
    let size: CGFloat
    var color: Color = Theme.ink

    var body: some View {
        let text = ByteFormat.string(bytes)
        let space = text.range(of: " ", options: .backwards)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            Text(space.map { String(text[..<$0.lowerBound]) } ?? text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if let space {
                Text(String(text[space.upperBound...]))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(color == Theme.ink ? Theme.ink2 : color)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

struct SpaceRing: View {
    let total: Int64
    let free: Int64
    let low: Bool

    private var used: Double { total > 0 ? min(max(Double(total - free) / Double(total), 0), 1) : 0 }
    private var colors: [Color] {
        low ? [Color(red: 1.0, green: 0.74, blue: 0.30), Color(red: 1.0, green: 0.45, blue: 0.20)]
            : [Color(red: 0.50, green: 0.84, blue: 0.78), Color(red: 0.09, green: 0.53, blue: 0.51)]
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.105
            // Round caps reach half a line past each end; when the free gap cannot hold them, the end would
            // lap over the start (a nearly full disk), so the arc ends flat and the gap shows as it is.
            let capsFit = 1 - used > line / (.pi * (size - line)) + 0.015
            ZStack {
                Circle().stroke(colors[1].opacity(0.13), lineWidth: line)
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * used)),
                            style: StrokeStyle(lineWidth: line, lineCap: capsFit ? .round : .butt))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors[1].opacity(0.28), radius: size * 0.03, y: size * 0.01)
                // Label, figure with a smaller unit, and the capacity in a quiet capsule.
                VStack(spacing: size * 0.02) {
                    Text("现在可用").font(.system(size: 12.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.ink3)
                    BigBytes(bytes: free, size: size * 0.17, color: low ? Theme.amber : Theme.ink)
                    Text(low ? "剩余空间较少" : "共 \(ByteFormat.string(total))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(low ? Theme.amber : Theme.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(low ? Theme.amber.opacity(0.14) : Theme.fill(0.06)))
                }
                .padding(.horizontal, line + size * 0.08)
            }
            .padding(line / 2)
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Every page opens the same way: what it is, what happens here, and its one main action on the right
/// (the overview's "outcome + button beside it", applied to the other pages).
struct PageHeader<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        // Actions beside the title while the words keep a comfortable width; below it in a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(symbol: symbol, tint: tint, size: 46)
                words.frame(minWidth: 360, alignment: .leading)
                Spacer(minLength: 16)
                actions
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    IconTile(symbol: symbol, tint: tint, size: 46)
                    words
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one main action on a page, as a capsule (Apple's primary-button shape on macOS 26).
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
            .background(Capsule().fill(Theme.blueFill))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: Theme.blue.opacity(0.35), radius: 14, y: 7)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}


/// GitHub's mark (Octicons, MIT), drawn from its SVG so it stays crisp and takes the surrounding colour.
struct GitHubMark: View {
    var size: CGFloat = 14

    private static let image: NSImage? = {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill="#000" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>"##
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.8, weight: .semibold))
        }
    }
}
