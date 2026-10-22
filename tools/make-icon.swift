// Makes app/AppIcon.icns from icon.svg: swift tools/make-icon.swift icon.svg app/AppIcon.icns
import AppKit
let svg = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .replacingOccurrences(of: "viewBox=\"0 0 800 600\"", with: "viewBox=\"253.3 216.2 46 46\"")
let art = NSImage(data: Data(svg.utf8))!
func tinted(_ c: NSColor) -> NSImage {
    let o = NSImage(size: CGSize(width: 46, height: 46)); o.lockFocus()
    art.draw(in: CGRect(x: 0, y: 0, width: 46, height: 46)); c.set()
    CGRect(x: 0, y: 0, width: 46, height: 46).fill(using: .sourceAtop); o.unlockFocus(); return o
}
/// One icon at `side` pixels: Apple's grid, a rounded tile 824/1024 of the canvas, the art 72% of the tile.
func icon(_ side: CGFloat, bg: [NSColor], fg: NSColor) -> NSImage {
    NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
        let t = side * 824 / 1024, o = (side - t) / 2
        let tile = CGRect(x: o, y: o + side * 0.01, width: t, height: t)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = side * 0.02; sh.shadowOffset = NSSize(width: 0, height: -side * 0.01)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
        let path = NSBezierPath(roundedRect: tile, xRadius: t * 0.225, yRadius: t * 0.225)
        bg[0].setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: bg)!.draw(in: path, angle: -90)
        let a = t * 0.72
        tinted(fg).draw(in: CGRect(x: tile.midX - a / 2, y: tile.midY - a / 2, width: a, height: a))
        return true
    }
}
let light: [NSColor] = [.white, NSColor(white: 0.90, alpha: 1)]
let out = CommandLine.arguments[2]
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon(px, bg: light, fg: .black).draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]; try! p.run(); p.waitUntilExit()
