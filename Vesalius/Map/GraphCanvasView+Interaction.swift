import AppKit
import VesaliusCore

/// Pointer interaction in progress.
enum MapInteraction {
    case idle
    /// Mouse is down on a node; becomes a drag after a few points of movement.
    case pressingNode(index: Int, start: CGPoint, origin: CGPoint, dragged: Bool)
    /// Mouse is down on empty canvas; becomes a pan after a few points of movement.
    case panning(start: CGPoint, center: CGPoint, moved: Bool)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

extension GraphCanvasView {
    // MARK: Hit testing

    /// The topmost node under a view-space point, with a small tolerance for tiny nodes.
    func nodeIndex(at point: CGPoint) -> Int? {
        var best: (index: Int, rank: Int, distance: CGFloat)?
        for (index, visual) in scene.visuals.enumerated() where visual.appear > 0.3 {
            let frame = viewFrame(of: visual)
            let rank: Int
            let distance: CGFloat
            switch visual.shape {
            case .circle:
                let radius = max(frame.width / 2, 4) + 3
                let dx = point.x - frame.midX, dy = point.y - frame.midY
                distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= radius else { continue }
                rank = 2
            case .square, .ghostSquare:
                guard frame.insetBy(dx: -3, dy: -3).contains(point) else { continue }
                distance = hypot(point.x - frame.midX, point.y - frame.midY)
                rank = 2
            case .card, .ghostCard:
                guard frame.contains(point) else { continue }
                distance = hypot(point.x - frame.midX, point.y - frame.midY)
                rank = visual.shape == .card ? 1 : 0
            }
            if let current = best, current.rank > rank || (current.rank == rank && current.distance <= distance) { continue }
            best = (index, rank, distance)
        }
        return best?.index
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    func updateHover(at point: CGPoint) {
        guard interaction.isIdle else { return }
        setHovered(nodeIndex(at: point).map { scene.visuals[$0].id })
    }

    private func setHovered(_ id: String?) {
        guard id != hoveredID else { return }
        hoveredID = id
        onHover?(id.flatMap { node(withID: $0) })
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let index = nodeIndex(at: point) {
            if event.clickCount >= 2 {
                interaction = .idle
                onActivate?(scene.visuals[index].node)
                return
            }
            interaction = .pressingNode(index: index, start: point, origin: scene.visuals[index].position, dragged: false)
        } else {
            interaction = .panning(start: point, center: camera.center, moved: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .idle:
            return
        case .pressingNode(let index, let start, let origin, let dragged):
            let dx = point.x - start.x, dy = point.y - start.y
            guard dragged || hypot(dx, dy) > 3, index < scene.visuals.count else { return }
            interaction = .pressingNode(index: index, start: start, origin: origin, dragged: true)
            moveNode(at: index, to: CGPoint(x: origin.x + dx / camera.zoom, y: origin.y + dy / camera.zoom))
            NSCursor.closedHand.set()
        case .panning(let start, let center, let moved):
            let dx = point.x - start.x, dy = point.y - start.y
            guard moved || hypot(dx, dy) > 2 else { return }
            interaction = .panning(start: start, center: center, moved: true)
            camera.center = CGPoint(x: center.x - dx / camera.zoom, y: center.y - dy / camera.zoom)
            NSCursor.closedHand.set()
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            interaction = .idle
            NSCursor.arrow.set()
            updateHover(at: convert(event.locationInWindow, from: nil))
        }
        switch interaction {
        case .pressingNode(let index, _, _, let dragged):
            if !dragged, index < scene.visuals.count { onSelect?(scene.visuals[index].node) }
        case .panning(_, _, let moved):
            if !moved { onSelect?(nil) }
        case .idle:
            break
        }
    }

    // MARK: Trackpad & wheel

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Two-finger scroll pans; the content follows the fingers.
            pan(by: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        } else {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.012 : event.scrollingDeltaY * 0.11
            guard amount != 0 else { return }
            zoom(by: exp(amount), around: point)
        }
        updateHover(at: point)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fit = fittingCamera(for: scene.restingBounds)
        if camera.zoom > fit.zoom * 1.4 {
            animateCamera(to: fit)
        } else {
            animateCamera(to: zoomed(camera, by: 2, around: point))
        }
    }
}

// MARK: - Accessibility

/// One map node exposed to VoiceOver and UI tests (`map-node-<id>`). AppKit's accessibility API is
/// nonisolated, so the element hops to the main actor whenever it needs the canvas.
nonisolated final class MapNodeAccessibilityElement: NSAccessibilityElement {
    let nodeID: String
    private weak var canvas: GraphCanvasView?

    @MainActor
    init(nodeID: String, label: String, value: String, canvas: GraphCanvasView) {
        self.nodeID = nodeID
        self.canvas = canvas
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityIdentifier("map-node-\(nodeID)")
        setAccessibilityParent(canvas)
    }

    override func accessibilityFrame() -> NSRect {
        let id = nodeID, canvas = canvas
        return Self.onMain { canvas?.accessibilityScreenFrame(for: id) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let id = nodeID, canvas = canvas
        return Self.onMain { canvas?.performAccessibilityPress(on: id) ?? false }
    }

    override func isAccessibilityElement() -> Bool { true }

    private static func onMain<T: Sendable>(_ work: @escaping @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}
