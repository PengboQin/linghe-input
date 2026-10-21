import AppKit
import Foundation

// Optical reduction of the approved crane / ā artwork. The menu needs a clean
// alpha mask, not the app icon's white tile, gradients, lettering or red accent.
// A 16-point canvas is intentional: visible ink stays smaller than the old ā.
let root = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let canvas = CGSize(width: 16, height: 16)

func drawCrane(in context: CGContext) {
    context.saveGState()
    context.translateBy(x: 0.8, y: 0.5)
    context.scaleBy(x: 0.22, y: 0.22)
    context.setFillColor(gray: 0, alpha: 1)
    let crane = CGMutablePath()
    // Rounded body, curved upright neck and a short crane beak.
    crane.move(to: CGPoint(x: 8, y: 33))
    crane.addCurve(to: CGPoint(x: 29, y: 32), control1: CGPoint(x: 15, y: 29), control2: CGPoint(x: 23, y: 29))
    crane.addCurve(to: CGPoint(x: 31, y: 42), control1: CGPoint(x: 33, y: 35), control2: CGPoint(x: 34, y: 37))
    crane.addCurve(to: CGPoint(x: 37, y: 55), control1: CGPoint(x: 27, y: 49), control2: CGPoint(x: 31, y: 54))
    crane.addCurve(to: CGPoint(x: 45, y: 53), control1: CGPoint(x: 40, y: 56), control2: CGPoint(x: 43, y: 55))
    crane.addLine(to: CGPoint(x: 56, y: 58))
    crane.addQuadCurve(to: CGPoint(x: 56, y: 56), control: CGPoint(x: 58, y: 58))
    crane.addLine(to: CGPoint(x: 45, y: 48))
    crane.addCurve(to: CGPoint(x: 42, y: 39), control1: CGPoint(x: 40, y: 46), control2: CGPoint(x: 39, y: 44))
    crane.addCurve(to: CGPoint(x: 45, y: 18), control1: CGPoint(x: 47, y: 31), control2: CGPoint(x: 49, y: 25))
    crane.addCurve(to: CGPoint(x: 15, y: 13), control1: CGPoint(x: 40, y: 9), control2: CGPoint(x: 24, y: 7))
    crane.addCurve(to: CGPoint(x: 8, y: 33), control1: CGPoint(x: 8, y: 18), control2: CGPoint(x: 7, y: 26))
    crane.closeSubpath()
    // Broad wing counter echoes the rounded ā in the full-size mother artwork.
    crane.move(to: CGPoint(x: 15, y: 25))
    crane.addCurve(to: CGPoint(x: 32, y: 29), control1: CGPoint(x: 21, y: 24), control2: CGPoint(x: 26, y: 31))
    crane.addCurve(to: CGPoint(x: 31, y: 17), control1: CGPoint(x: 39, y: 27), control2: CGPoint(x: 38, y: 19))
    crane.addCurve(to: CGPoint(x: 15, y: 25), control1: CGPoint(x: 22, y: 14), control2: CGPoint(x: 13, y: 18))
    crane.closeSubpath()
    context.addPath(crane)
    context.drawPath(using: .eoFill)
    context.restoreGState()
}

let image = NSImage(size: canvas)
image.isTemplate = true
for pixels in [16, 32] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.bitmapData!.initialize(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
    rep.size = canvas
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // NSGraphicsContext already maps rep.size (points) to pixelsWide/High.
    drawCrane(in: context)
    image.addRepresentation(rep)
}
let tiff=image.tiffRepresentation!
try tiff.write(to: root.appendingPathComponent("design/brand/input-source-icon.tiff"))
// The canonical name also carries AppKit's Template convention. Do not supply
// the same fixed black artwork as an alternate/highlight icon: the system owns
// the tint for a dark menu bar, including dark wallpaper in Light appearance.
for name in ["LingheCraneMenuTemplate.tiff","LingheCraneMenu.tiff","PrivateInput.tiff","PrivateInputTemplate.tiff"] {try tiff.write(to:root.appendingPathComponent("apple/macOS/InputMethod/"+name))}

let pdf = NSMutableData()
let consumer = CGDataConsumer(data: pdf as CFMutableData)!
var box = CGRect(origin: .zero, size: canvas)
let context = CGContext(consumer: consumer, mediaBox: &box,
    [kCGPDFContextTitle: "Linghe compact crane template"] as CFDictionary)!
context.beginPDFPage(nil)
drawCrane(in: context)
context.endPDFPage()
context.closePDF()
try (pdf as Data).write(to: root.appendingPathComponent("apple/macOS/InputMethod/LingheInputMenu.pdf"))
print("Exported 16pt compact crane template: vector PDF + 1×/2× TIFF")
