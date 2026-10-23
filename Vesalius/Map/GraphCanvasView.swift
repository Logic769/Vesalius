import AppKit
import QuartzCore
import VesaliusCore

/// Maps world coordinates (layout space, y down) to view coordinates.
struct MapCamera: Equatable {
    var center: CGPoint = .zero
    var zoom: CGFloat = 1

    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 6
    /// Fitting never magnifies small graphs beyond this.
    static let maximumFitZoom: CGFloat = 1.5
    static let maximumPointFitZoom: CGFloat = 2.4

    static func clamp(_ zoom: CGFloat) -> CGFloat { min(maximumZoom, max(minimumZoom, zoom)) }
}

/// The System Map: an interactive, animated rendering of a `MapGraph`.
///
/// Layout runs off the main thread (`GraphLayoutEngine`); drawing is Core Graphics in view space so
/// strokes and text stay crisp at every zoom level.
final class GraphCanvasView: NSView {
    // MARK: Host interface

    var onSelect: ((MapNode?) -> Void)?
    var onActivate: ((MapNode) -> Void)?
    var onHover: ((MapNode?) -> Void)?

    /// Space kept clear when fitting content (room for host overlays such as breadcrumbs and legends).
    var contentInsets = NSEdgeInsets(top: 64, left: 40, bottom: 52, right: 40)

    /// Duration of the most recent layout, for diagnostics.
    private(set) var lastLayoutMilliseconds: Double = 0

    // MARK: Scene state

    var scene = MapScene()
    var departing: [MapNodeVisual] = []
    var camera = MapCamera()
    var selection: String?
    var highlighted: Set<String> = []
    var edgeFilter: MapEdgeFilter = .all
    var colorMode: MapColorMode = .area
    var showLabels = true
    var hoveredID: String?
    var pinnedIDs: Set<String> = []
    let text = MapTextCache()
    let palette = MapColorAssigner()

    var interaction = MapInteraction.idle
    var accessibilityNodes: [MapNodeAccessibilityElement] = []

    private var structureKey: UInt64?
    private var pendingKey: UInt64?
    private var pendingGraph: MapGraph?
    private var layoutGeneration = 0
    private var layoutTask: Task<Void, Never>?
    private var lastFitToken: Int?
    private var lastZoomToken: Int?
    private var needsInitialFit = false

    private var transition: (start: CFTimeInterval, duration: CFTimeInterval)?
    private var cameraAnimation: (start: CFTimeInterval, duration: CFTimeInterval, from: MapCamera, to: MapCamera)?
    private var displayLink: CADisplayLink?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityIdentifier("system-map")
        setAccessibilityLabel("System Map")
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Updates from the host

    func update(graph: MapGraph, selection: String?, highlighted: Set<String>, edgeFilter: MapEdgeFilter, colorMode: MapColorMode, showLabels: Bool, fitToken: Int, zoomToken: (Int, Double)) {
        apply(graph)
        var redraw = false
        if selection != self.selection {
            self.selection = selection
            redraw = true
            revealSelectionIfNeeded()
        }
        if highlighted != self.highlighted {
            self.highlighted = highlighted
            redraw = true
        }
        if edgeFilter != self.edgeFilter {
            self.edgeFilter = edgeFilter
            redraw = true
        }
        if colorMode != self.colorMode {
            self.colorMode = colorMode
            redraw = true
        }
        if showLabels != self.showLabels {
            self.showLabels = showLabels
            redraw = true
        }
        if let last = lastFitToken, last != fitToken {
            animateCamera(to: fittingCamera(for: scene.restingBounds))
        }
        lastFitToken = fitToken
        if let last = lastZoomToken, last != zoomToken.0, zoomToken.1 > 0 {
            var target = cameraAnimation?.to ?? camera
            let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
            target = zoomed(target, by: CGFloat(zoomToken.1), around: anchor)
            animateCamera(to: target, duration: 0.25)
        }
        lastZoomToken = zoomToken.0
        if redraw { needsDisplay = true }
    }

    private func apply(_ graph: MapGraph) {
        let key = MapScene.structureKey(graph)
        if key == pendingKey {
            pendingGraph = graph
            return
        }
        if key == structureKey && pendingKey == nil {
            if let current = scene.graph, current.nodes == graph.nodes, current.edges == graph.edges { return }
            scene.refresh(with: graph, text: text)
            refreshAccessibilityLabels()
            needsDisplay = true
            return
        }
        pendingKey = key
        pendingGraph = nil
        let next = MapScene.build(graph, text: text)
        let request = layoutRequest(for: next)
        layoutGeneration += 1
        let generation = layoutGeneration
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GraphLayoutEngine.layout(request)
            }.value
            guard let self, !Task.isCancelled, generation == self.layoutGeneration else { return }
            self.install(next, layout: result, key: key)
        }
    }

    private func layoutRequest(for next: MapScene) -> GraphLayoutRequest {
        let nodes = next.visuals.map { visual -> GraphLayoutNode in
            var initial: CGPoint?
            if let current = scene.index[visual.id] {
                initial = scene.visuals[current].to
            }
            return GraphLayoutNode(
                id: visual.id,
                group: visual.groupKey,
                size: visual.size,
                isRect: visual.shape.isRect,
                gap: visual.shape.isRect ? GraphLayoutEngine.cardGap : (visual.shape == .circle ? GraphLayoutEngine.pointGap : GraphLayoutEngine.symbolGap),
                mass: visual.sizeShare,
                initial: initial,
                pinned: initial != nil && pinnedIDs.contains(visual.id)
            )
        }
        let edges = next.edges.indices.map { index in
            GraphLayoutEdge(source: next.endpoints[index].source, target: next.endpoints[index].target, weight: Double(max(1, next.edges[index].weight)))
        }
        return GraphLayoutRequest(nodes: nodes, edges: edges)
    }

    /// Swaps in a laid-out scene and choreographs the transition from the previous one.
    private func install(_ incoming: MapScene, layout: GraphLayoutResult, key: UInt64) {
        let old = scene
        var next = incoming
        palette.prepare(Set(next.visuals.map(\.groupKey)))
        if let latest = pendingGraph { next.refresh(with: latest, text: text) }
        lastLayoutMilliseconds = layout.milliseconds
        var targets = layout.positions
        let persisted = next.visuals.contains { old.index[$0.id] != nil }

        // Place the new layout relative to the old one so navigation reads spatially.
        var offset = CGPoint.zero
        let layoutCenter = CGPoint(x: layout.bounds.midX, y: layout.bounds.midY)
        var collapseTarget: CGPoint?
        if !persisted, !old.visuals.isEmpty {
            if let focus = next.graph?.focus, let opened = old.index[focus] {
                let anchor = old.visuals[opened].position
                offset = CGPoint(x: anchor.x - layoutCenter.x, y: anchor.y - layoutCenter.y)
            } else if let oldFocus = old.graph?.focus, let parent = next.index[oldFocus] {
                let anchor = old.contentCenter
                offset = CGPoint(x: anchor.x - targets[parent].x, y: anchor.y - targets[parent].y)
                collapseTarget = anchor
            } else {
                offset = CGPoint(x: camera.center.x - layoutCenter.x, y: camera.center.y - layoutCenter.y)
            }
        }
        for i in targets.indices {
            targets[i].x += offset.x
            targets[i].y += offset.y
        }

        let animate = !old.visuals.isEmpty
        for i in next.visuals.indices {
            let target = targets[i]
            next.visuals[i].to = target
            if let previous = old.index[next.visuals[i].id] {
                next.visuals[i].from = old.visuals[previous].position
                next.visuals[i].appearFrom = 1
            } else if animate, let spawn = spawnPoint(for: next.visuals[i], old: old, next: next) {
                next.visuals[i].from = spawn
                next.visuals[i].appearFrom = 0.2
            } else {
                next.visuals[i].from = target
                next.visuals[i].appearFrom = animate ? 0 : 0.4
            }
            next.visuals[i].position = next.visuals[i].from
            next.visuals[i].appear = next.visuals[i].appearFrom
        }

        departing = animate ? old.visuals.filter { next.index[$0.id] == nil }.map { visual in
            var leaving = visual
            leaving.from = visual.position
            leaving.to = collapseTarget ?? visual.position
            return leaving
        } : []

        scene = next
        structureKey = key
        pendingKey = nil
        pendingGraph = nil
        pinnedIDs = pinnedIDs.filter { scene.index[$0] != nil }
        if let hovered = hoveredID, scene.index[hovered] == nil { hoveredID = nil }
        interaction = .idle

        let bounds = scene.restingBounds
        needsInitialFit = self.bounds.width < 10 || self.bounds.height < 10
        userMovedCamera = false
        if animate {
            transition = (CACurrentMediaTime(), 0.42)
            animateCamera(to: fittingCamera(for: bounds), duration: 0.45)
        } else {
            camera = fittingCamera(for: bounds)
            transition = (CACurrentMediaTime(), 0.28)
            startDisplayLink()
        }
        rebuildAccessibilityElements()
        needsDisplay = true
    }

    /// Where a node that did not exist before should grow from.
    private func spawnPoint(for visual: MapNodeVisual, old: MapScene, next: MapScene) -> CGPoint? {
        if visual.node.kind == .external, let path = visual.node.path, let index = old.index[path] {
            return old.visuals[index].position
        }
        if let focus = next.graph?.focus, let index = old.index[focus] {
            return old.visuals[index].position
        }
        if let oldFocus = old.graph?.focus, oldFocus == visual.id {
            return old.contentCenter
        }
        if let match = old.visuals.first(where: { $0.node.label == visual.groupKey && $0.shape.isRect }) {
            return match.position
        }
        return nil
    }

    // MARK: Camera

    func toView(_ point: CGPoint, camera: MapCamera? = nil) -> CGPoint {
        let cam = camera ?? self.camera
        return CGPoint(x: (point.x - cam.center.x) * cam.zoom + bounds.midX, y: (point.y - cam.center.y) * cam.zoom + bounds.midY)
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - bounds.midX) / camera.zoom + camera.center.x, y: (point.y - bounds.midY) / camera.zoom + camera.center.y)
    }

    func fittingCamera(for content: CGRect) -> MapCamera {
        guard !content.isNull, bounds.width > 10, bounds.height > 10 else {
            return MapCamera(center: content.isNull ? .zero : CGPoint(x: content.midX, y: content.midY), zoom: 1)
        }
        let available = CGRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: max(40, bounds.width - contentInsets.left - contentInsets.right),
            height: max(40, bounds.height - contentInsets.top - contentInsets.bottom)
        )
        var zoom = min(available.width / max(content.width, 1), available.height / max(content.height, 1))
        // Cards carry text and look oversized when magnified; small point graphs can come closer.
        let hasCards = scene.visuals.contains { $0.shape.isRect }
        zoom = min(hasCards ? MapCamera.maximumFitZoom : MapCamera.maximumPointFitZoom, MapCamera.clamp(zoom))
        // Map the content centre to the centre of the available area, not of the whole view.
        let center = CGPoint(
            x: content.midX - (available.midX - bounds.midX) / zoom,
            y: content.midY - (available.midY - bounds.midY) / zoom
        )
        return MapCamera(center: center, zoom: zoom)
    }

    func zoomed(_ camera: MapCamera, by factor: CGFloat, around point: CGPoint) -> MapCamera {
        let newZoom = MapCamera.clamp(camera.zoom * factor)
        let world = CGPoint(x: (point.x - bounds.midX) / camera.zoom + camera.center.x, y: (point.y - bounds.midY) / camera.zoom + camera.center.y)
        let center = CGPoint(x: world.x - (point.x - bounds.midX) / newZoom, y: world.y - (point.y - bounds.midY) / newZoom)
        return MapCamera(center: center, zoom: newZoom)
    }

    func zoom(by factor: CGFloat, around point: CGPoint) {
        userMovedCamera = true
        cameraAnimation = nil
        camera = zoomed(camera, by: factor, around: point)
        needsDisplay = true
    }

    func pan(by delta: CGVector) {
        userMovedCamera = true
        cameraAnimation = nil
        camera.center.x -= delta.dx / camera.zoom
        camera.center.y -= delta.dy / camera.zoom
        needsDisplay = true
    }

    func animateCamera(to target: MapCamera, duration: CFTimeInterval = 0.35) {
        cameraAnimation = (CACurrentMediaTime(), duration, camera, target)
        startDisplayLink()
    }

    /// Brings a newly selected node into view when it is off screen.
    private func revealSelectionIfNeeded() {
        guard let selection, let index = scene.index[selection], bounds.width > 0 else { return }
        let point = toView(scene.visuals[index].to)
        let visible = bounds.insetBy(dx: 40, dy: 40)
        guard !visible.contains(point) else { return }
        var target = camera
        target.center = scene.visuals[index].to
        animateCamera(to: target)
    }

    /// Set once the user pans or zooms; until then the graph keeps fitting the view as it resizes
    /// (window resizing, sidebar or inspector appearing).
    var userMovedCamera = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if (needsInitialFit || !userMovedCamera), bounds.width >= 10, bounds.height >= 10, !scene.visuals.isEmpty {
            needsInitialFit = false
            cameraAnimation = nil
            camera = fittingCamera(for: scene.restingBounds)
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Animation clock

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if transition != nil || cameraAnimation != nil {
            // Animations started before the view joined a window need a clock tied to its screen.
            stopDisplayLink()
            startDisplayLink()
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var active = false
        if let transition {
            let raw = min(1, (now - transition.start) / transition.duration)
            let t = CGFloat(Self.easeOut(raw))
            for i in scene.visuals.indices {
                let visual = scene.visuals[i]
                scene.visuals[i].position = CGPoint(x: visual.from.x + (visual.to.x - visual.from.x) * t, y: visual.from.y + (visual.to.y - visual.from.y) * t)
                scene.visuals[i].appear = visual.appearFrom + (1 - visual.appearFrom) * t
            }
            for i in departing.indices {
                let visual = departing[i]
                departing[i].position = CGPoint(x: visual.from.x + (visual.to.x - visual.from.x) * t, y: visual.from.y + (visual.to.y - visual.from.y) * t)
                departing[i].fade = 1 - t
            }
            if raw >= 1 {
                self.transition = nil
                departing = []
            } else {
                active = true
            }
        }
        if let animation = cameraAnimation {
            let raw = min(1, (now - animation.start) / animation.duration)
            let t = CGFloat(Self.easeOut(raw))
            let from = animation.from, to = animation.to
            let zoom = from.zoom * pow(to.zoom / from.zoom, t)
            camera = MapCamera(center: CGPoint(x: from.center.x + (to.center.x - from.center.x) * t, y: from.center.y + (to.center.y - from.center.y) * t), zoom: zoom)
            if raw >= 1 {
                cameraAnimation = nil
            } else {
                active = true
            }
        }
        needsDisplay = true
        if !active { stopDisplayLink() }
    }

    nonisolated static func easeOut(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return 1 - pow(1 - clamped, 3)
    }

    // MARK: Lookup

    func node(withID id: String) -> MapNode? {
        scene.index[id].map { scene.visuals[$0].node }
    }

    /// Moves a node (user drag) and pins it.
    func moveNode(at index: Int, to world: CGPoint) {
        scene.visuals[index].position = world
        scene.visuals[index].from = world
        scene.visuals[index].to = world
        pinnedIDs.insert(scene.visuals[index].id)
        needsDisplay = true
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? { accessibilityNodes }

    func rebuildAccessibilityElements() {
        accessibilityNodes = scene.visuals.map { visual in
            MapNodeAccessibilityElement(nodeID: visual.id, label: visual.node.label, value: accessibilityValue(for: visual.node), canvas: self)
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func refreshAccessibilityLabels() {
        for element in accessibilityNodes {
            guard let node = node(withID: element.nodeID) else { continue }
            element.setAccessibilityLabel(node.label)
            element.setAccessibilityValue(accessibilityValue(for: node))
        }
    }

    private func accessibilityValue(for node: MapNode) -> String {
        var parts: [String] = []
        if node.kind == .module || node.kind == .directory || node.kind == .external {
            parts.append("\(node.files) files")
        }
        parts.append("\(node.lines) lines")
        if node.diagnostics > 0 { parts.append("\(node.diagnostics) diagnostics") }
        return parts.joined(separator: ", ")
    }

    /// Screen-space frame for an accessibility element.
    func accessibilityScreenFrame(for id: String) -> NSRect {
        guard let index = scene.index[id], let window else { return .zero }
        let rect = viewFrame(of: scene.visuals[index])
        return window.convertToScreen(convert(rect, to: nil))
    }

    func performAccessibilityPress(on id: String) -> Bool {
        guard let node = node(withID: id) else { return false }
        onSelect?(node)
        return true
    }

    /// The node's frame in view coordinates.
    func viewFrame(of visual: MapNodeVisual) -> CGRect {
        let center = toView(visual.position)
        let scale = camera.zoom * max(0.05, visual.appear)
        return CGRect(x: center.x - visual.size.width * scale / 2, y: center.y - visual.size.height * scale / 2, width: visual.size.width * scale, height: visual.size.height * scale)
    }
}
