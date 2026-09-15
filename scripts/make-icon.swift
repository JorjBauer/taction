// Renders the app icon, 1024 x 1024: the hand-and-dot artwork from Resources/hand-source.png
// (white shapes on a flat background) composited onto a rounded gradient tile, with two ripple
// arcs drawn around the dot the finger points at.
//
// Usage: swift scripts/make-icon.swift out.png [hand-source.png]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
// Run from the package root (as bundle.sh does), or pass the artwork path as the second argument.
let sourcePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/hand-source.png"
let side: CGFloat = 1024

// MARK: Load the artwork and turn its white shapes into an alpha mask

guard let source = NSImage(contentsOfFile: sourcePath),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read \(sourcePath)\n", stderr)
    exit(1)
}
let w = cg.width, h = cg.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let readCtx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("cannot create bitmap\n", stderr)
    exit(1)
}
readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// White is anything whose darkest channel is bright; the blue background has a dark red channel.
var glyph = [UInt8](repeating: 0, count: w * h * 4)
var minX = w, minY = h, maxX = 0, maxY = 0
var dotSumX = 0.0, dotSumY = 0.0, dotCount = 0.0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let m = min(pixels[i], pixels[i + 1], pixels[i + 2])
        let a = max(0, min(255, (Int(m) - 150) * 255 / 80))
        if a > 0 {
            glyph[i] = UInt8(a); glyph[i + 1] = UInt8(a); glyph[i + 2] = UInt8(a); glyph[i + 3] = UInt8(a)
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            // The dot is the only white thing in the upper right; average its pixels for the center.
            if x > w * 2 / 3 && y < h * 2 / 5 {
                dotSumX += Double(x) * Double(a); dotSumY += Double(y) * Double(a); dotCount += Double(a)
            }
        }
    }
}
guard dotCount > 0, maxX > minX else {
    fputs("no white artwork found in \(sourcePath)\n", stderr)
    exit(1)
}
let dotCenterPx = CGPoint(x: dotSumX / dotCount, y: dotSumY / dotCount)   // top-left origin
// Dot radius from its area: the counted alpha sum is roughly the pixel count.
let dotRadiusPx = sqrt((dotCount / 255) / .pi)

guard let glyphCtx = CGContext(data: &glyph, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let glyphImage = glyphCtx.makeImage() else {
    fputs("cannot build glyph image\n", stderr)
    exit(1)
}

// MARK: Layout

// Scale the artwork so the hand plus dot spans a comfortable share of the tile, leaving room for the
// arcs beyond the dot, and place it slightly low and left so the ripples balance the composition.
let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
let bboxWidth = CGFloat(maxX - minX + 1)
let scale = tile.width * 0.66 / bboxWidth
let artOrigin = NSPoint(x: tile.minX + tile.width * 0.10 - CGFloat(minX) * scale,
                        y: tile.minY + tile.height * 0.10 - CGFloat(h - 1 - maxY) * scale)
let artRect = NSRect(x: artOrigin.x, y: artOrigin.y, width: CGFloat(w) * scale, height: CGFloat(h) * scale)
// The dot's center and radius in canvas coordinates (y up).
let dot = NSPoint(x: artOrigin.x + dotCenterPx.x * scale, y: artOrigin.y + (CGFloat(h) - dotCenterPx.y) * scale)
let dotR = dotRadiusPx * scale

// Ripples: two arcs centered on the dot, opening away from the finger (which points up and to the right).
let pointingAngle: CGFloat = 40
func ripplePaths() -> [NSBezierPath] {
    [1.9, 2.75].map { factor -> NSBezierPath in
        let p = NSBezierPath()
        p.appendArc(withCenter: dot, radius: dotR * factor, startAngle: pointingAngle - 62, endAngle: pointingAngle + 62)
        p.lineWidth = dotR * 0.42
        p.lineCapStyle = .round
        return p
    }
}

// MARK: Render

let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18)
    let top = NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.86, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.62, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: tilePath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let gloss = NSBezierPath(ovalIn: NSRect(x: tile.minX - tile.width * 0.2, y: tile.midY, width: tile.width * 1.4, height: tile.height * 0.9))
    NSColor.white.withAlphaComponent(0.08).setFill()
    gloss.fill()
    NSGraphicsContext.restoreGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = side * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    NSImage(cgImage: glyphImage, size: NSSize(width: w, height: h)).draw(in: artRect)
    NSColor.white.setStroke()
    for ripple in ripplePaths() { ripple.stroke() }
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("could not render icon\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (dot at \(Int(dot.x)),\(Int(dot.y)) r=\(Int(dotR)))")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
