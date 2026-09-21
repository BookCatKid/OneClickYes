import AppKit

// OneClickYes icon: macOS rounded-rect tile, green gradient (approval),
// bold white checkmark with a small cursor arrow "clicking" it.

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

NSColor.clear.set()
NSRect(x: 0, y: 0, width: S, height: S).fill()

// Tile: standard macOS icon geometry (~824pt artwork in 1024 canvas)
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = (S - inset * 2) * 0.2237
let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Subtle drop shadow under the tile
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)

NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.set()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Green gradient, lighter at top
NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).set()
tilePath.fill()

// Bold white checkmark, slightly shadowed
let check = NSBezierPath()
check.lineWidth = 150
check.lineCapStyle = .round
check.lineJoinStyle = .round
let cx = S / 2, cy = S / 2
check.move(to: NSPoint(x: cx - 200, y: cy + 20))
check.line(to: NSPoint(x: cx - 55, y: cy - 135))
check.line(to: NSPoint(x: cx + 215, y: cy + 145))

NSGraphicsContext.saveGraphicsState()
let cshadow = NSShadow()
cshadow.shadowColor = NSColor(white: 0, alpha: 0.28)
cshadow.shadowBlurRadius = 14
cshadow.shadowOffset = NSSize(width: 0, height: -8)
cshadow.set()
NSColor.white.setStroke()
check.stroke()
NSGraphicsContext.restoreGraphicsState()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: "/tmp/ocy_icon_1024.png"))
print("wrote /tmp/ocy_icon_1024.png")
