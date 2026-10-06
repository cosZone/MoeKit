import AppKit

/// Original small-size adaptation of MoeKit's approved ghost-and-toolbox
/// mascot. Vector template artwork: the menu bar supplies its own ink at 1x/2x.
/// The app icon, artwork files and other brands are unchanged.
enum MenuBarIcon {
    static let size = NSSize(width: 22, height: 22)
    static let frameCount = 24
    static let frameMilliseconds = 30

    struct Pose: Equatable, Sendable {
        var tilt: Double = 0
        var rise: Double = 0
        var blink: Bool = false
    }

    static func pose(frame: Int) -> Pose {
        guard frame > 0, frame < frameCount else { return Pose() }
        let t = Double(frame) / Double(frameCount)
        // A single friendly nod, then stillness. Different periods let the
        // lift lead the turn; both envelopes reach zero at either endpoint.
        let envelope = pow(sin(.pi * t), 2)
        return Pose(tilt: 5 * sin(2 * .pi * t) * envelope,
                    rise: 0.8 * sin(.pi * t) * envelope,
                    blink: (0.40...0.50).contains(t))
    }

    static func image(activity: MenuBarActivity, frame: Int = 0) -> NSImage {
        let pose = pose(frame: frame)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(activity: activity, pose: pose)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MoeKit"
        return image
    }

    private static func draw(activity: MenuBarActivity, pose: Pose) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: 11, yBy: CGFloat(10 + pose.rise))
        transform.rotate(byDegrees: CGFloat(pose.tilt))
        transform.translateX(by: -11, yBy: -10)
        transform.concat()
        NSColor.black.set()
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 4, y: 8))
        body.curve(to: NSPoint(x: 11, y: 19), controlPoint1: NSPoint(x: 4, y: 16), controlPoint2: NSPoint(x: 6.4, y: 19))
        body.curve(to: NSPoint(x: 18, y: 8), controlPoint1: NSPoint(x: 15.6, y: 19), controlPoint2: NSPoint(x: 18, y: 16))
        body.line(to: NSPoint(x: 18, y: 4.5))
        body.curve(to: NSPoint(x: 14.3, y: 3), controlPoint1: NSPoint(x: 18, y: 1.8), controlPoint2: NSPoint(x: 15.8, y: 1.8))
        body.curve(to: NSPoint(x: 7.7, y: 3), controlPoint1: NSPoint(x: 12.4, y: 1), controlPoint2: NSPoint(x: 9.6, y: 1))
        body.curve(to: NSPoint(x: 4, y: 4.5), controlPoint1: NSPoint(x: 6.2, y: 1.8), controlPoint2: NSPoint(x: 4, y: 1.8))
        body.close()
        body.lineWidth = 1.35
        body.lineJoinStyle = .round
        body.stroke()
        for x in [8.1, 13.1] {
            let eye = NSBezierPath(roundedRect: NSRect(x: x, y: pose.blink ? 12.65 : 12.2,
                                                       width: 1.1, height: pose.blink ? 0.45 : 1.5),
                                   xRadius: 0.55, yRadius: 0.55)
            eye.fill()
        }
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 9.5, y: 10.8))
        smile.curve(to: NSPoint(x: 12.5, y: 10.8), controlPoint1: NSPoint(x: 10.2, y: 9.6), controlPoint2: NSPoint(x: 11.8, y: 9.6))
        smile.lineWidth = 0.9; smile.lineCapStyle = .round; smile.stroke()
        let toolbox = NSBezierPath(roundedRect: NSRect(x: 6.2, y: 4.8, width: 9.6, height: 3.4), xRadius: 1, yRadius: 1)
        toolbox.lineWidth = 1.1; toolbox.stroke()
        let handle = NSBezierPath(roundedRect: NSRect(x: 9.3, y: 7.7, width: 3.4, height: 1.5), xRadius: 0.65, yRadius: 0.65)
        handle.lineWidth = 1; handle.stroke()
        // The badge remains geometrically stable while the mascot nods.
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        guard [.busy, .completed, .attention].contains(activity) else { return }
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: NSRect(x: 13.2, y: 0.2, width: 8.2, height: 8.2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: 14.3, y: 1.3, width: 6, height: 6))
        ring.lineWidth = 1.1; ring.stroke()
        let mark = NSBezierPath()
        mark.lineWidth = 1.05; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
        switch activity {
        case .busy:
            mark.move(to: NSPoint(x: 17.3, y: 5.8)); mark.line(to: NSPoint(x: 17.3, y: 4.3)); mark.line(to: NSPoint(x: 18.4, y: 3.5))
        case .completed:
            mark.move(to: NSPoint(x: 15.9, y: 4.3)); mark.line(to: NSPoint(x: 17, y: 3.3)); mark.line(to: NSPoint(x: 18.7, y: 5.3))
        case .attention:
            mark.move(to: NSPoint(x: 17.3, y: 5.8)); mark.line(to: NSPoint(x: 17.3, y: 4.3))
            NSBezierPath(ovalIn: NSRect(x: 16.8, y: 2.6, width: 1, height: 1)).fill()
        default: break
        }
        mark.stroke()
    }
}
