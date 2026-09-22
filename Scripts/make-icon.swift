import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let dimension = size * scale
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.lockFocus()
        let d = CGFloat(dimension)
        NSColor(calibratedRed: 0.06, green: 0.085, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: d * 0.07, y: d * 0.07, width: d * 0.86, height: d * 0.86), xRadius: d * 0.19, yRadius: d * 0.19).fill()
        NSColor(calibratedRed: 0.36, green: 0.85, blue: 0.87, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: d * 0.26, y: d * 0.26, width: d * 0.48, height: d * 0.48))
        ring.lineWidth = d * 0.035
        ring.stroke()
        let center = NSBezierPath(ovalIn: NSRect(x: d * 0.38, y: d * 0.38, width: d * 0.24, height: d * 0.24))
        center.lineWidth = d * 0.018
        center.stroke()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let b = a + .pi / 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: d * (0.5 + 0.12 * cos(a)), y: d * (0.5 + 0.12 * sin(a))))
            line.line(to: NSPoint(x: d * (0.5 + 0.24 * cos(b)), y: d * (0.5 + 0.24 * sin(b))))
            line.lineWidth = d * 0.018
            line.stroke()
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
