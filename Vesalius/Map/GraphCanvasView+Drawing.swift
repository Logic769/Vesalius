import AppKit
import VesaliusCore

/// How an edge is emphasised in the current frame.
enum MapEdgeStyle: Int, Comparable {
    case dimmed, neutral, hoverIncoming, hoverOutgoing, incoming, outgoing

    static func < (lhs: MapEdgeStyle, rhs: MapEdgeStyle) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Per-frame emphasis derived from selection, hover, highlight and the edge filter.
struct MapEmphasis {
    var nodeAlpha: [CGFloat]
    var edgeStyle: [MapEdgeStyle]
    var selected: Int?
    var hovered: Int?
    /// Nodes whose labels must be shown (selection, its neighbours, hover, search matches).
    var forcedLabels: Set<Int>
    var highlightedNodes: Set<Int>
}

/// Colours resolved once per frame for the view's appearance.
struct MapFrameColors {
    let background: CGColor
    let gridDot: CGColor
    let edgeNeutral: CGColor
    let edgeDimmed: CGColor
    let dependents: CGColor
    let dependencies: CGColor
    let cycle: CGColor
    let accent: CGColor
    let highlight: CGColor
    let ghost: CGColor
    let isDark: Bool

    static func resolve(for appearance: NSAppearance) -> MapFrameColors {
        var colors: MapFrameColors?
        appearance.performAsCurrentDrawingAppearance {
            colors = MapFrameColors(
                background: MapPalette.canvasBackground.cgColor,
                gridDot: MapPalette.gridDot.cgColor,
                edgeNeutral: MapPalette.edgeNeutral.cgColor,
                edgeDimmed: MapPalette.edgeDimmed.cgColor,
                dependents: MapPalette.dependents.cgColor,
                dependencies: MapPalette.dependencies.cgColor,
                cycle: MapPalette.cycle.cgColor,
                accent: NSColor.controlAccentColor.cgColor,
                highlight: MapPalette.highlightRing.cgColor,
                ghost: MapPalette.ghostStroke.cgColor,
                isDark: appearance.isMapDark
            )
        }
        return colors ?? MapFrameColors(
            background: CGColor(gray: 1, alpha: 1), gridDot: CGColor(gray: 0, alpha: 0.1), edgeNeutral: CGColor(gray: 0, alpha: 0.2),
            edgeDimmed: CGColor(gray: 0, alpha: 0.05), dependents: CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1),
            dependencies: CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1), cycle: CGColor(red: 0.85, green: 0.25, blue: 0.3, alpha: 1),
            accent: CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1), highlight: CGColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1),
            ghost: CGColor(gray: 0, alpha: 0.3), isDark: false
        )
    }
}

extension GraphCanvasView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = MapFrameColors.resolve(for: effectiveAppearance)
        context.setFillColor(colors.background)
        context.fill(bounds)
        drawGrid(context, colors)

        guard !scene.visuals.isEmpty || !departing.isEmpty else {
            drawEmptyState()
            return
        }
        let emphasis = makeEmphasis()
        var nodeColors: [CGColor] = []
        nodeColors.reserveCapacity(scene.visuals.count)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nodeColors = scene.visuals.map { baseColor(for: $0).cgColor }
        }
        drawEdges(context, emphasis, colors)
        drawDeparting(context, colors)
        drawNodes(context, emphasis, nodeColors, colors)
        drawLabels(emphasis)
        drawTooltip(emphasis)
    }

    // MARK: Colour mapping

    func baseColor(for visual: MapNodeVisual) -> NSColor {
        switch colorMode {
        case .area: palette.color(visual.groupKey)
        case .language: MapPalette.languageColor(visual.node.language)
        case .health: visual.node.diagnostics > 0 ? MapPalette.severityColor(visual.node.maxSeverity ?? .info) : MapPalette.healthy
        case .risk: MapPalette.riskColor(visual.node.risk)
        }
    }

    // MARK: Emphasis

    func makeEmphasis() -> MapEmphasis {
        let count = scene.visuals.count
        var alpha = Array(repeating: CGFloat(1), count: count)
        var styles = Array(repeating: MapEdgeStyle.neutral, count: scene.edges.count)
        var forced = Set<Int>()
        var highlightedNodes = Set<Int>()
        let selected = selection.flatMap { scene.index[$0] }
        let hovered = hoveredID.flatMap { scene.index[$0] }

        for id in highlighted {
            if let index = scene.index[id] { highlightedNodes.insert(index) }
        }

        if let s = selected {
            alpha = Array(repeating: effectiveAppearance.isMapDark ? 0.22 : 0.2, count: count)
            styles = Array(repeating: .dimmed, count: scene.edges.count)
            alpha[s] = 1
            forced.insert(s)
            if edgeFilter != .outgoing {
                for e in scene.incoming[s] {
                    styles[e] = .incoming
                    let source = scene.endpoints[e].source
                    alpha[source] = 1
                    forced.insert(source)
                }
            }
            if edgeFilter != .incoming {
                for e in scene.outgoing[s] {
                    styles[e] = .outgoing
                    let target = scene.endpoints[e].target
                    alpha[target] = 1
                    forced.insert(target)
                }
            }
        } else if !highlightedNodes.isEmpty {
            alpha = Array(repeating: 0.28, count: count)
            for index in highlightedNodes {
                alpha[index] = 1
                forced.insert(index)
            }
            for (e, ends) in scene.endpoints.enumerated() where alpha[ends.source] < 1 && alpha[ends.target] < 1 {
                styles[e] = .dimmed
            }
        }

        if let h = hovered {
            forced.insert(h)
            alpha[h] = max(alpha[h], 0.92)
            if selected == nil {
                for e in scene.incoming[h] where styles[e] != .dimmed { styles[e] = .hoverIncoming }
                for e in scene.outgoing[h] where styles[e] != .dimmed { styles[e] = .hoverOutgoing }
            }
        }
        return MapEmphasis(nodeAlpha: alpha, edgeStyle: styles, selected: selected, hovered: hovered, forcedLabels: forced, highlightedNodes: highlightedNodes)
    }

    // MARK: Background

    private func drawGrid(_ context: CGContext, _ colors: MapFrameColors) {
        var spacing = 26 * camera.zoom
        guard spacing.isFinite, spacing > 0 else { return }
        while spacing < 15 { spacing *= 2 }
        while spacing > 54 { spacing /= 2 }
        let origin = toView(.zero)
        var startX = origin.x.truncatingRemainder(dividingBy: spacing)
        var startY = origin.y.truncatingRemainder(dividingBy: spacing)
        if startX < 0 { startX += spacing }
        if startY < 0 { startY += spacing }
        let scale = window?.backingScaleFactor ?? 2
        let dot: CGFloat = 1.6 / scale + 0.5
        var rects: [CGRect] = []
        rects.reserveCapacity(Int((bounds.width / spacing + 1) * (bounds.height / spacing + 1)))
        var x = startX
        while x < bounds.maxX {
            var y = startY
            let px = (x * scale).rounded() / scale
            while y < bounds.maxY {
                let py = (y * scale).rounded() / scale
                rects.append(CGRect(x: px - dot / 2, y: py - dot / 2, width: dot, height: dot))
                y += spacing
            }
            x += spacing
        }
        context.setFillColor(colors.gridDot)
        context.fill(rects)
    }

    private func drawEmptyState() {
        let message = scene.graph == nil ? "" : "Nothing to show at this level"
        guard !message.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        (message as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    // MARK: Edges

    private struct EdgeBucket: Hashable {
        let style: MapEdgeStyle
        let dashed: Bool
        let width: Int
        /// Index into the frame's tint colours (edges inside one area take its colour), or -1.
        let tint: Int
    }

    private struct HeadBucket: Hashable {
        let style: MapEdgeStyle
        let tint: Int
    }

    private func drawEdges(_ context: CGContext, _ emphasis: MapEmphasis, _ colors: MapFrameColors) {
        guard !scene.edges.isEmpty else { return }
        let zoom = camera.zoom
        let widthScale = min(1.3, max(0.7, zoom.squareRoot()))
        let arrowScale = min(1.2, max(0.75, zoom.squareRoot()))
        let showArrows = zoom > 0.2
        // Dense graphs keep neutral arrows only once zoomed in; emphasised edges always show them.
        let neutralArrows = scene.edges.count <= 260 || zoom >= 1.6
        let cull = bounds.insetBy(dx: -80, dy: -80)

        // Edges inside one area are tinted with its colour (in area mode), so clusters read at a glance.
        var tintIndex: [String: Int] = [:]
        var tintColors: [CGColor] = []
        if colorMode == .area {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for visual in scene.visuals where tintIndex[visual.groupKey] == nil {
                    tintIndex[visual.groupKey] = tintColors.count
                    tintColors.append(palette.color(visual.groupKey).cgColor)
                }
            }
        }
        // Many neutral edges add up to haze; thin them out as the graph gets denser.
        let density = min(1, max(0.4, (140 / Double(max(1, scene.edges.count))).squareRoot()))

        var lines: [EdgeBucket: CGMutablePath] = [:]
        var heads: [HeadBucket: CGMutablePath] = [:]
        var fading: [(path: CGPath, head: CGPath?, style: MapEdgeStyle, dashed: Bool, width: CGFloat, alpha: CGFloat)] = []

        for (e, edge) in scene.edges.enumerated() {
            let ends = scene.endpoints[e]
            let a = scene.visuals[ends.source], b = scene.visuals[ends.target]
            let pa = toView(a.position), pb = toView(b.position)
            let box = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
            guard box.insetBy(dx: -60, dy: -60).intersects(cull) else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 2 else { continue }

            let style = emphasis.edgeStyle[e]
            var width = min(2.8, max(0.6, 0.6 + 0.42 * log(CGFloat(max(1, edge.weight))))) * widthScale
            switch style {
            case .incoming, .outgoing: width += 0.6
            case .hoverIncoming, .hoverOutgoing: width += 0.3
            case .dimmed: width *= 0.8
            case .neutral: break
            }

            // Curve to the left of the direction of travel, so A→B and B→A separate.
            let nx = -dy / length, ny = dx / length
            let bend = min(length * 0.12, 56)
            let control = CGPoint(x: (pa.x + pb.x) / 2 + nx * bend, y: (pa.y + pb.y) / 2 + ny * bend)
            let arrowLength = (5.5 + width) * arrowScale
            let tip = boundaryPoint(of: b, center: pb, toward: control, padding: 1.5)
            let start = boundaryPoint(of: a, center: pa, toward: control, padding: 1.5)
            let toward = CGPoint(x: tip.x - control.x, y: tip.y - control.y)
            let towardLength = max(0.001, (toward.x * toward.x + toward.y * toward.y).squareRoot())
            let direction = CGPoint(x: toward.x / towardLength, y: toward.y / towardLength)
            let end = showArrows ? CGPoint(x: tip.x - direction.x * arrowLength * 0.8, y: tip.y - direction.y * arrowLength * 0.8) : tip

            let wantsHead = showArrows && style != .dimmed && (style != .neutral || neutralArrows)
            let base = CGPoint(x: tip.x - direction.x * arrowLength, y: tip.y - direction.y * arrowLength)
            let half = arrowLength * 0.42
            let wingA = CGPoint(x: base.x - direction.y * half, y: base.y + direction.x * half)
            let wingB = CGPoint(x: base.x + direction.y * half, y: base.y - direction.x * half)

            let appear = min(a.appear, b.appear)
            if appear < 0.999 {
                let line = CGMutablePath()
                line.move(to: start)
                line.addQuadCurve(to: end, control: control)
                var head: CGMutablePath?
                if wantsHead {
                    let arrow = CGMutablePath()
                    arrow.addLines(between: [tip, wingA, wingB])
                    arrow.closeSubpath()
                    head = arrow
                }
                fading.append((line, head, style, edge.isCycle, width, appear * appear))
                continue
            }
            var tint = -1
            if style == .neutral && !edge.isCycle && a.groupKey == b.groupKey, let index = tintIndex[a.groupKey] {
                tint = index
            }
            // Append straight into the shared bucket path: one stroke per style instead of per edge.
            let bucket = EdgeBucket(style: style, dashed: edge.isCycle, width: Int((width * 4).rounded()), tint: tint)
            let path = lines[bucket] ?? CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            lines[bucket] = path
            if wantsHead {
                let key = HeadBucket(style: style, tint: tint)
                let heads_ = heads[key] ?? CGMutablePath()
                heads_.addLines(between: [tip, wingA, wingB])
                heads_.closeSubpath()
                heads[key] = heads_
            }
        }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        func strokeColor(_ style: MapEdgeStyle, dashed: Bool, tint: Int) -> CGColor {
            if tint >= 0 {
                let alpha: CGFloat = (colors.isDark ? 0.42 : 0.36) * density
                return tintColors[tint].copy(alpha: alpha) ?? tintColors[tint]
            }
            let color = edgeColor(style, dashed: dashed, colors)
            guard style == .neutral && !dashed else { return color }
            return color.copy(alpha: color.alpha * density) ?? color
        }
        for bucket in lines.keys.sorted(by: { ($0.style, $0.dashed ? 1 : 0, $0.tint, $0.width) < ($1.style, $1.dashed ? 1 : 0, $1.tint, $1.width) }) {
            guard let path = lines[bucket] else { continue }
            context.setStrokeColor(strokeColor(bucket.style, dashed: bucket.dashed, tint: bucket.tint))
            context.setLineWidth(CGFloat(bucket.width) / 4)
            if bucket.dashed {
                context.setLineDash(phase: 0, lengths: [5, 3.5])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(path)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        for key in heads.keys.sorted(by: { ($0.style, $0.tint) < ($1.style, $1.tint) }) {
            guard let path = heads[key] else { continue }
            if key.tint >= 0 {
                context.setFillColor(tintColors[key.tint].copy(alpha: (colors.isDark ? 0.6 : 0.55) * density) ?? tintColors[key.tint])
            } else if key.style == .neutral {
                let color = arrowColor(.neutral, colors)
                context.setFillColor(color.copy(alpha: color.alpha * density) ?? color)
            } else {
                context.setFillColor(arrowColor(key.style, colors))
            }
            context.addPath(path)
            context.fillPath()
        }
        for item in fading {
            context.setAlpha(item.alpha)
            context.setStrokeColor(edgeColor(item.style, dashed: item.dashed, colors))
            context.setLineWidth(item.width)
            context.setLineDash(phase: 0, lengths: item.dashed ? [5, 3.5] : [])
            context.addPath(item.path)
            context.strokePath()
            if let head = item.head {
                context.setFillColor(arrowColor(item.style, colors))
                context.addPath(head)
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    private func edgeColor(_ style: MapEdgeStyle, dashed: Bool, _ colors: MapFrameColors) -> CGColor {
        switch style {
        case .dimmed: colors.edgeDimmed
        case .neutral: dashed ? colors.cycle.copy(alpha: 0.78) ?? colors.cycle : colors.edgeNeutral
        case .hoverIncoming: colors.dependents.copy(alpha: 0.7) ?? colors.dependents
        case .hoverOutgoing: colors.dependencies.copy(alpha: 0.7) ?? colors.dependencies
        case .incoming: colors.dependents
        case .outgoing: colors.dependencies
        }
    }

    private func arrowColor(_ style: MapEdgeStyle, _ colors: MapFrameColors) -> CGColor {
        switch style {
        case .neutral: colors.edgeNeutral.copy(alpha: min(1, colors.edgeNeutral.alpha + 0.12)) ?? colors.edgeNeutral
        default: edgeColor(style, dashed: false, colors)
        }
    }

    /// Where a line from the node centre toward `point` leaves the node outline (view space).
    func boundaryPoint(of visual: MapNodeVisual, center: CGPoint, toward point: CGPoint, padding: CGFloat) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let ux = dx / length, uy = dy / length
        let scale = camera.zoom * max(0.05, visual.appear)
        let distance: CGFloat
        switch visual.shape {
        case .circle:
            distance = visual.size.width / 2 * scale
        case .card, .ghostCard, .square, .ghostSquare:
            let hw = visual.size.width / 2 * scale, hh = visual.size.height / 2 * scale
            let tx = abs(ux) > 0.0001 ? hw / abs(ux) : .greatestFiniteMagnitude
            let ty = abs(uy) > 0.0001 ? hh / abs(uy) : .greatestFiniteMagnitude
            distance = min(tx, ty)
        }
        return CGPoint(x: center.x + ux * (distance + padding), y: center.y + uy * (distance + padding))
    }

    // MARK: Nodes

    private func drawDeparting(_ context: CGContext, _ colors: MapFrameColors) {
        guard !departing.isEmpty else { return }
        var departingColors: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            departingColors = departing.map { baseColor(for: $0).cgColor }
        }
        for (visual, color) in zip(departing, departingColors) where visual.fade > 0.01 {
            let frame = viewFrame(of: visual)
            guard frame.intersects(bounds.insetBy(dx: -40, dy: -40)) else { continue }
            drawNode(context, visual, frame: frame, color: color, alpha: visual.fade * 0.9, state: [], colors: colors)
        }
    }

    struct NodeState: OptionSet {
        let rawValue: Int
        static let selected = NodeState(rawValue: 1)
        static let hovered = NodeState(rawValue: 2)
        static let highlighted = NodeState(rawValue: 4)
    }

    private func drawNodes(_ context: CGContext, _ emphasis: MapEmphasis, _ nodeColors: [CGColor], _ colors: MapFrameColors) {
        let visible = bounds.insetBy(dx: -40, dy: -40)
        // Painter's order: ghosts, cards, dimmed points, bright points, then the focus on top.
        let order = scene.visuals.indices.sorted { a, b in
            let ra = drawRank(a, emphasis), rb = drawRank(b, emphasis)
            return ra == rb ? a < b : ra < rb
        }
        for index in order {
            let visual = scene.visuals[index]
            var state: NodeState = []
            if emphasis.selected == index { state.insert(.selected) }
            if emphasis.hovered == index { state.insert(.hovered) }
            if emphasis.highlightedNodes.contains(index) { state.insert(.highlighted) }
            var frame = viewFrame(of: visual)
            if state.contains(.hovered) && interaction.isIdle {
                frame = frame.insetBy(dx: -frame.width * 0.035, dy: -frame.height * 0.035)
            }
            guard frame.intersects(visible) else { continue }
            drawNode(context, visual, frame: frame, color: nodeColors[index], alpha: emphasis.nodeAlpha[index] * min(1, max(0, visual.appear * 1.2)), state: state, colors: colors)
        }
    }

    private func drawRank(_ index: Int, _ emphasis: MapEmphasis) -> Int {
        let visual = scene.visuals[index]
        if emphasis.selected == index || emphasis.hovered == index { return 6 }
        switch visual.shape {
        case .ghostCard, .ghostSquare: return 0
        case .card: return emphasis.nodeAlpha[index] < 1 ? 1 : 2
        case .circle, .square: return emphasis.nodeAlpha[index] < 1 ? 3 : (emphasis.highlightedNodes.contains(index) ? 5 : 4)
        }
    }

    private func drawNode(_ context: CGContext, _ visual: MapNodeVisual, frame: CGRect, color: CGColor, alpha: CGFloat, state: NodeState, colors: MapFrameColors) {
        guard alpha > 0.005 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        if state.contains(.hovered) || state.contains(.selected) {
            context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 9, color: CGColor(gray: 0, alpha: colors.isDark ? 0.55 : 0.18))
        }
        switch visual.shape {
        case .card: drawCard(context, visual, frame: frame, color: color, state: state, colors: colors)
        case .ghostCard: drawGhostCard(context, visual, frame: frame, colors: colors)
        case .circle: drawCircle(context, visual, frame: frame, color: color, state: state, colors: colors)
        case .square, .ghostSquare: drawSquare(context, visual, frame: frame, color: color, state: state, colors: colors)
        }
        context.restoreGState()
    }

    private func drawCard(_ context: CGContext, _ visual: MapNodeVisual, frame: CGRect, color: CGColor, state: NodeState, colors: MapFrameColors) {
        let scale = frame.height / max(1, visual.size.height)
        let radius = min(10, max(2.5, 8 * scale))
        let rect = frame.integral.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.setFillColor(colors.background)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(color.copy(alpha: colors.isDark ? 0.19 : 0.13) ?? color)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(color.copy(alpha: colors.isDark ? 0.62 : 0.58) ?? color)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        drawRings(context, around: rect, cornerRadius: radius, state: state, colors: colors)

        // Content scales with the card; it disappears when too small to read.
        guard scale >= 0.42 else { return }
        let node = visual.node
        let paddingX = 12 * scale
        let dotSize = 7 * scale
        let titleSize = 12.5 * scale
        let titleFont = text.font(size: titleSize, weight: .semibold)
        let dotRect = CGRect(x: rect.minX + paddingX, y: rect.minY + (scale >= 0.62 ? 13.5 : (rect.height - 7) / 2) * scale, width: dotSize, height: dotSize)
        // The dot carries the card's identity colour (its area), never a status colour.
        context.setFillColor(color)
        context.fillEllipse(in: dotRect)

        let textX = dotRect.maxX + 6 * scale
        let chevronWidth: CGFloat = node.isExpandable ? 14 * scale : 4 * scale
        let available = rect.maxX - textX - chevronWidth - 6 * scale
        if scale >= 0.62 {
            drawText(node.label, in: CGRect(x: textX, y: rect.minY + 7.5 * scale, width: available, height: titleSize * 1.35), font: titleFont, color: .labelColor)
            let detailFont = text.font(size: 10.5 * scale, weight: .regular, monospacedDigits: true)
            var detailWidth = available
            if node.diagnostics > 0, let severity = node.maxSeverity, severity >= .medium {
                detailWidth -= drawBadge(count: node.diagnostics, severity: severity, rightEdge: rect.maxX - chevronWidth - 4 * scale, centerY: rect.minY + 32 * scale, scale: scale, context: context)
            }
            drawText(MapScene.cardDetail(node), in: CGRect(x: textX, y: rect.minY + 25.5 * scale, width: detailWidth, height: 10.5 * scale * 1.4), font: detailFont, color: .secondaryLabelColor)
        } else {
            drawText(node.label, in: CGRect(x: textX, y: rect.midY - titleSize * 0.68, width: available, height: titleSize * 1.35), font: titleFont, color: .labelColor)
        }
        if node.isExpandable && scale >= 0.55 {
            let chevronFont = text.font(size: 12 * scale, weight: .semibold)
            drawText("›", in: CGRect(x: rect.maxX - chevronWidth - 2 * scale, y: rect.midY - 12 * scale * 0.7, width: chevronWidth, height: 12 * scale * 1.4), font: chevronFont, color: .tertiaryLabelColor, alignment: .center)
        }
    }

    /// Draws a severity badge right-aligned at `rightEdge`; returns the width it used.
    private func drawBadge(count: Int, severity: Severity, rightEdge: CGFloat, centerY: CGFloat, scale: CGFloat, context: CGContext) -> CGFloat {
        let label = count > 99 ? "99+" : "\(count)"
        let font = text.font(size: 9.5 * scale, weight: .semibold, monospacedDigits: true)
        let textWidth = text.width(label, font: font)
        let height = 13 * scale
        let width = max(height, textWidth + 8 * scale)
        let rect = CGRect(x: rightEdge - width, y: centerY - height / 2, width: width, height: height)
        var severityColor = CGColor(gray: 0.5, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            severityColor = MapPalette.severityColor(severity).cgColor
        }
        context.setFillColor(severityColor.copy(alpha: 0.18) ?? severityColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        drawText(label, in: rect.offsetBy(dx: 0, dy: (height - font.boundingRectForFont.height * 0.9) / 2 - 0.5 * scale), font: font, color: NSColor(cgColor: severityColor) ?? .labelColor, alignment: .center)
        return width + 6 * scale
    }

    private func drawGhostCard(_ context: CGContext, _ visual: MapNodeVisual, frame: CGRect, colors: MapFrameColors) {
        let scale = frame.height / max(1, visual.size.height)
        let radius = min(9, max(2.5, 7 * scale))
        let rect = frame.integral.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setFillColor(colors.background.copy(alpha: 0.92) ?? colors.background)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(colors.ghost)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.addPath(path)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        guard scale >= 0.45 else { return }
        let font = text.font(size: 11.5 * scale, weight: .medium)
        drawText("↗ " + visual.node.label, in: CGRect(x: rect.minX + 9 * scale, y: rect.midY - 11.5 * scale * 0.68, width: rect.width - 16 * scale, height: 11.5 * scale * 1.4), font: font, color: .secondaryLabelColor)
    }

    private func drawCircle(_ context: CGContext, _ visual: MapNodeVisual, frame: CGRect, color: CGColor, state: NodeState, colors: MapFrameColors) {
        let radius = frame.width / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if radius < 1.4 {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
            return
        }
        // A halo in the canvas colour separates the node from edges passing underneath.
        let halo = max(1.25, min(2.2, radius * 0.18))
        context.setFillColor(colors.background)
        context.fillEllipse(in: frame.insetBy(dx: -halo, dy: -halo))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        if visual.node.isTest {
            context.setFillColor(color.copy(alpha: colors.isDark ? 0.16 : 0.1) ?? color)
            context.fillEllipse(in: frame)
            context.setStrokeColor(color)
            context.setLineWidth(max(1, min(2, radius * 0.18)))
            context.strokeEllipse(in: frame.insetBy(dx: 0.75, dy: 0.75))
        } else {
            context.setFillColor(color)
            context.fillEllipse(in: frame)
            // Subtle inner edge for definition on light backgrounds.
            context.setStrokeColor(CGColor(gray: colors.isDark ? 1 : 0, alpha: colors.isDark ? 0.14 : 0.12))
            context.setLineWidth(0.75)
            context.strokeEllipse(in: frame.insetBy(dx: 0.375, dy: 0.375))
        }
        var ringOffset: CGFloat = 0
        if let severity = visual.node.maxSeverity, severity >= .medium, visual.node.diagnostics > 0, radius >= 3 {
            var severityColor = color
            effectiveAppearance.performAsCurrentDrawingAppearance {
                severityColor = MapPalette.severityColor(severity).cgColor
            }
            ringOffset = 3.25
            context.setStrokeColor(severityColor)
            context.setLineWidth(1.6)
            context.strokeEllipse(in: frame.insetBy(dx: -ringOffset, dy: -ringOffset))
        }
        if state.contains(.selected) {
            let offset = ringOffset + 3.75
            context.setStrokeColor(colors.accent)
            context.setLineWidth(2.25)
            context.strokeEllipse(in: frame.insetBy(dx: -offset, dy: -offset))
        } else if state.contains(.highlighted) {
            let offset = ringOffset + 3.5
            context.setStrokeColor(colors.highlight)
            context.setLineWidth(2)
            context.strokeEllipse(in: frame.insetBy(dx: -offset, dy: -offset))
        }
    }

    private func drawSquare(_ context: CGContext, _ visual: MapNodeVisual, frame: CGRect, color: CGColor, state: NodeState, colors: MapFrameColors) {
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(2, rect.width * 0.24)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setFillColor(colors.background)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius + 1.5, cornerHeight: radius + 1.5, transform: nil))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let ghost = visual.shape == .ghostSquare
        if ghost {
            context.setStrokeColor(colors.ghost)
            context.setLineDash(phase: 0, lengths: [3, 2.5])
        } else {
            context.setFillColor(color.copy(alpha: colors.isDark ? 0.26 : 0.16) ?? color)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(color.copy(alpha: 0.8) ?? color)
        }
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        drawRings(context, around: rect, cornerRadius: radius, state: state, colors: colors)
        guard rect.width >= 10 else { return }
        let font = text.font(size: rect.width * 0.5, weight: .bold)
        let glyphColor: NSColor = ghost ? .tertiaryLabelColor : (NSColor(cgColor: color) ?? .labelColor)
        drawText(MapScene.glyph(for: visual.node.symbolKind), in: CGRect(x: rect.minX, y: rect.midY - rect.width * 0.5 * 0.62, width: rect.width, height: rect.width * 0.5 * 1.3), font: font, color: glyphColor, alignment: .center)
    }

    private func drawRings(_ context: CGContext, around rect: CGRect, cornerRadius: CGFloat, state: NodeState, colors: MapFrameColors) {
        if state.contains(.selected) {
            let ring = rect.insetBy(dx: -3.5, dy: -3.5)
            context.setStrokeColor(colors.accent)
            context.setLineWidth(2.25)
            context.addPath(CGPath(roundedRect: ring, cornerWidth: cornerRadius + 3.5, cornerHeight: cornerRadius + 3.5, transform: nil))
            context.strokePath()
        } else if state.contains(.highlighted) {
            let ring = rect.insetBy(dx: -3, dy: -3)
            context.setStrokeColor(colors.highlight)
            context.setLineWidth(2)
            context.addPath(CGPath(roundedRect: ring, cornerWidth: cornerRadius + 3, cornerHeight: cornerRadius + 3, transform: nil))
            context.strokePath()
        }
    }

    func drawText(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .natural) {
        guard rect.width > 4, rect.height > 2 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: Labels

    private func drawLabels(_ emphasis: MapEmphasis) {
        let zoom = camera.zoom
        let pointNodes = scene.visuals.indices.filter { scene.visuals[$0].shape == .circle || scene.visuals[$0].shape == .square || scene.visuals[$0].shape == .ghostSquare }
        guard !pointNodes.isEmpty else { return }
        let small = pointNodes.count <= 40
        let threshold: Double = zoom >= 1.1 ? 0 : zoom >= 0.75 ? 0.22 : zoom >= 0.5 ? 0.42 : 0.68
        var candidates: [(index: Int, priority: Double)] = []
        for index in pointNodes {
            let visual = scene.visuals[index]
            guard visual.appear > 0.6 else { continue }
            let forced = emphasis.forcedLabels.contains(index)
            if !forced {
                guard showLabels, emphasis.nodeAlpha[index] >= 0.9 else { continue }
                guard small && zoom >= 0.45 || visual.importance >= threshold else { continue }
            }
            var priority = visual.importance
            if forced { priority += 2 }
            if emphasis.selected == index || emphasis.hovered == index { priority += 3 }
            candidates.append((index, priority))
        }
        candidates.sort { $0.priority == $1.priority ? $0.index < $1.index : $0.priority > $1.priority }

        // A label budget proportional to the visible area keeps dense maps calm.
        let budget: Int = {
            if zoom >= 2.2 { return 400 }
            let area = bounds.width * bounds.height
            let perLabel: CGFloat = zoom >= 1.5 ? 9_000 : (zoom >= 1 ? 20_000 : 34_000)
            return max(8, Int(area / perLabel))
        }()
        var placed: [CGRect] = []
        var drawn = 0
        // Footprints of clearly visible nodes, which labels should not cover.
        let nodeRects: [(index: Int, rect: CGRect)] = scene.visuals.indices.compactMap { index in
            guard emphasis.nodeAlpha[index] >= 0.9 else { return nil }
            let rect = viewFrame(of: scene.visuals[index]).insetBy(dx: -2, dy: -2)
            return rect.intersects(bounds) ? (index, rect) : nil
        }
        let regular = text.font(size: 11, weight: .regular)
        let strong = text.font(size: 11, weight: .semibold)
        let halo = MapPalette.canvasBackground.withAlphaComponent(0.92)
        for candidate in candidates.prefix(400) {
            let forcedLabel = emphasis.forcedLabels.contains(candidate.index)
            if drawn >= budget && !forcedLabel { break }
            let visual = scene.visuals[candidate.index]
            let frame = viewFrame(of: visual)
            guard frame.intersects(bounds) else { continue }
            let emphasised = emphasis.selected == candidate.index || emphasis.hovered == candidate.index
            let font = emphasised ? strong : regular
            var label = visual.node.label
            if label.count > 32 { label = String(label.prefix(30)) + "…" }
            let width = text.width(label, font: font)
            let height: CGFloat = 15
            let ringSpace: CGFloat = (visual.node.maxSeverity.map { $0 >= .medium } ?? false) ? 5 : 2
            // Try below, above, right and left; keep the first spot clear of labels and nodes.
            let positions = [
                CGRect(x: frame.midX - width / 2 - 3, y: frame.maxY + ringSpace + 1, width: width + 6, height: height),
                CGRect(x: frame.midX - width / 2 - 3, y: frame.minY - ringSpace - 1 - height, width: width + 6, height: height),
                CGRect(x: frame.maxX + ringSpace + 2, y: frame.midY - height / 2, width: width + 6, height: height),
                CGRect(x: frame.minX - ringSpace - 8 - width, y: frame.midY - height / 2, width: width + 6, height: height),
            ]
            let clear = positions.first { candidateRect in
                !placed.contains { $0.intersects(candidateRect) } && !nodeRects.contains { $0.index != candidate.index && $0.rect.intersects(candidateRect) }
            }
            guard let rect = clear ?? (emphasised ? positions[0] : nil) else { continue }
            placed.append(rect)
            drawn += 1
            let color: NSColor = emphasised ? .labelColor : (visual.shape == .ghostSquare ? .tertiaryLabelColor : .secondaryLabelColor)
            let origin = CGPoint(x: rect.minX + 3, y: rect.minY + 0.5)
            // A halo in the canvas colour keeps text legible over edges without boxes.
            (label as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: halo, .strokeColor: halo, .strokeWidth: 32])
            (label as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    // MARK: Tooltip

    private func drawTooltip(_ emphasis: MapEmphasis) {
        guard let index = emphasis.hovered, interaction.isIdle else { return }
        let visual = scene.visuals[index]
        guard visual.appear > 0.95 else { return }
        let node = visual.node
        var lines: [(String, NSFont, NSColor)] = []
        lines.append((node.label, text.font(size: 12, weight: .semibold), .labelColor))
        lines.append((kindDescription(node), text.font(size: 11, weight: .regular), .secondaryLabelColor))
        let statsFont = text.font(size: 11, weight: .regular, monospacedDigits: true)
        switch node.kind {
        case .module, .directory, .external:
            let symbols = node.symbols > 0 ? " · \(node.symbols.formatted()) symbols" : ""
            lines.append(("\(node.files) file\(node.files == 1 ? "" : "s") · \(node.lines.formatted()) lines\(symbols)", statsFont, .secondaryLabelColor))
        case .file:
            let symbols = node.symbols > 0 ? " · \(node.symbols) symbols" : ""
            lines.append(("\(node.lines.formatted()) lines\(symbols)", statsFont, .secondaryLabelColor))
        case .symbol:
            lines.append(("\(node.lines.formatted()) lines", statsFont, .secondaryLabelColor))
        }
        if node.fanIn > 0 || node.fanOut > 0 {
            lines.append(("used by \(node.fanIn) · depends on \(node.fanOut)", statsFont, .secondaryLabelColor))
        }
        if node.diagnostics > 0 {
            let severity = node.maxSeverity.map { " · \($0.rawValue)" } ?? ""
            lines.append(("\(node.diagnostics) diagnostic\(node.diagnostics == 1 ? "" : "s")\(severity)", statsFont, MapPalette.severityColor(node.maxSeverity ?? .info)))
        }
        if node.isExpandable {
            lines.append((node.kind == .file ? "Double-click to show symbols" : "Double-click to open", text.font(size: 10.5, weight: .regular), .tertiaryLabelColor))
        }

        let widths = lines.map { text.width($0.0, font: $0.1) }
        let width = min(360, (widths.max() ?? 80) + 24)
        let lineHeights = lines.map { ceil($0.1.ascender - $0.1.descender + 3) }
        let height = lineHeights.reduce(0, +) + 14
        let frame = viewFrame(of: visual)
        var origin = CGPoint(x: frame.maxX + 12, y: frame.minY - 4)
        if origin.x + width > bounds.maxX - 8 { origin.x = frame.minX - width - 12 }
        origin.x = max(bounds.minX + 8, origin.x)
        origin.y = min(max(bounds.minY + 8, origin.y), bounds.maxY - height - 8)
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.isMapDark
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 14, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.16))
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(MapPalette.tooltipBackground.cgColor)
            context.addPath(path)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(MapPalette.tooltipBorder.cgColor)
        }
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        context.strokePath()
        context.restoreGState()

        var y = rect.minY + 7
        for (line, height) in zip(lines, lineHeights) {
            drawText(line.0, in: CGRect(x: rect.minX + 12, y: y, width: width - 24, height: height), font: line.1, color: line.2)
            y += height
        }
    }

    private func kindDescription(_ node: MapNode) -> String {
        let language = node.language.map { " · \($0.displayName)" } ?? ""
        switch node.kind {
        case .module: return "Module" + language
        case .directory: return "Folder" + (node.path.map { " · \($0)" } ?? "")
        case .file: return "File" + language + (node.isTest ? " · test" : "")
        case .symbol: return (node.symbolKind?.displayName.capitalized ?? "Symbol") + language
        case .external:
            if let kind = node.symbolKind { return "\(kind.displayName.capitalized) in \(node.group ?? "another file")" }
            return "Outside this view"
        }
    }
}
