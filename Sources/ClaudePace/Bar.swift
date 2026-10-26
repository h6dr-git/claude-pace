import AppKit

/// Monochrome usage-bar rendering. No color carries meaning — everything is
/// conveyed by geometry (fill length = used, empty = remaining, tick = pace).
/// Images are templates so they auto-adapt to light/dark menu bar & menus.
enum Bar {
    /// Draw one horizontal bar into `rect` on the current graphics context.
    /// `used`/`pace` are 0...1.
    static func draw(in rect: CGRect, used: Double, pace: Double?) {
        let h = rect.height
        let r = min(3, h / 2)

        // track (faint)
        NSColor.black.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()

        // fill (used) — grows left→right, like Claude's native usage bars
        let u = CGFloat(max(0, min(1, used)))
        if u > 0 {
            let w = max(h, rect.width * u)              // keep a visible nub when tiny
            let fr = CGRect(x: rect.minX, y: rect.minY, width: w, height: h)
            NSColor.black.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: fr, xRadius: r, yRadius: r).fill()
        }

        // pace tick — "where you should be by now". Pokes above/below the bar
        // so it reads as a separate marker without relying on color.
        if let pace, pace >= 0, pace <= 1 {
            let x = rect.minX + rect.width * CGFloat(pace)
            NSColor.black.setFill()
            NSBezierPath(rect: CGRect(x: x - 0.75, y: rect.minY - 1.5, width: 1.5, height: h + 3)).fill()
        }
    }

    /// A single bar image (for dropdown rows).
    static func image(used: Double, pace: Double?, width: CGFloat = 140, height: CGFloat = 9) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        draw(in: CGRect(x: 0, y: 0, width: width, height: height), used: used, pace: pace)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// Compact ring for the menu bar (the real-time 5h view). Square footprint.
    /// Fill arc = used (grows clockwise from 12 o'clock); radial tick = pace
    /// ("where you should be by now" = elapsed fraction). Monochrome template.
    static func ringImage(used: Double, pace: Double?, diameter: CGFloat = 17, lineWidth: CGFloat = 3) -> NSImage {
        let size = diameter + 4                 // padding so the pace tick can poke out
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let c = NSPoint(x: size / 2, y: size / 2)
        let r = diameter / 2 - lineWidth / 2

        // track
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(0.22).setStroke()
        track.stroke()

        // used arc — start at top (90°), sweep clockwise
        let u = max(0, min(1, used))
        if u > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - CGFloat(u) * 360, clockwise: true)
            NSColor.black.withAlphaComponent(0.92).setStroke()
            arc.stroke()
        }

        // pace marker — radial tick at the elapsed-fraction position (same
        // clockwise-from-top mapping as the fill). Fill behind the tick = under
        // pace (room to burn). Pokes across the ring; geometry, not color.
        if let pace, pace >= 0, pace <= 1 {
            let a = (90 - Double(pace) * 360) * .pi / 180
            let inner = r - lineWidth / 2 - 1.0
            let outer = r + lineWidth / 2 + 1.0
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            tick.line(to: NSPoint(x: c.x + CGFloat(cos(a)) * outer, y: c.y + CGFloat(sin(a)) * outer))
            tick.lineWidth = 1.3
            tick.lineCapStyle = .round
            NSColor.black.setStroke()
            tick.stroke()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
