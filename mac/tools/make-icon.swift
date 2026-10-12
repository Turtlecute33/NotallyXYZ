// Makes Resources/AppIcon.png (1024 px, macOS icon grid) from the square NotallyX icon.
// Usage: swift tools/make-icon.swift <square-icon.png> Resources/AppIcon.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: make-icon.swift <input.png> <output.png>"); exit(1)
}
let size = 1024, inset: CGFloat = 100, radius: CGFloat = 185
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSColor(red: 0x72 / 255, green: 0x85 / 255, blue: 0xD0 / 255, alpha: 1).setFill()
path.fill()
NSShadow().set()
path.addClip()
source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
