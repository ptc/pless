// Generiert das pless-App-Icon als iconset (alle PNG-Größen, per CoreGraphics gezeichnet).
// Nutzung: swift Scripts/make-icon.swift <ziel-iconset-dir>
// Danach: iconutil -c icns <iconset-dir> -o pless.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "pless.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Zeichnet das Icon in `size`×`size` Pixeln (Vektor — jede Größe wird scharf neu gezeichnet).
/// Design: abgerundetes Quadrat mit blauem Verlauf, weiße Dokumentseite mit geknickter
/// rechter oberer Ecke, drei Textzeilen. Koordinaten: CGContext ist y-up (oben = großes y).
func render(size: Int, to name: String) throws {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "pless.icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein CGContext"])
    }

    // Hintergrund: abgerundetes Quadrat, Verlauf hellblau (oben) → dunkelblau (unten)
    let corner = s * 0.2247
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    let top = CGColor(red: 0.36, green: 0.62, blue: 0.94, alpha: 1)
    let bottom = CGColor(red: 0.15, green: 0.35, blue: 0.72, alpha: 1)
    guard let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else {
        throw NSError(domain: "pless.icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "kein Gradient"])
    }
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Dokumentseite (weiß) mit abgeschnittener rechter oberer Ecke
    let dw = s * 0.44, dh = s * 0.58
    let dx = (s - dw) / 2, dy = (s - dh) / 2 - s * 0.01
    let fold = s * 0.13
    let doc = CGMutablePath()
    doc.move(to: CGPoint(x: dx, y: dy))
    doc.addLine(to: CGPoint(x: dx + dw, y: dy))
    doc.addLine(to: CGPoint(x: dx + dw, y: dy + dh - fold))
    doc.addLine(to: CGPoint(x: dx + dw - fold, y: dy + dh))
    doc.addLine(to: CGPoint(x: dx, y: dy + dh))
    doc.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(doc)
    ctx.fillPath()

    // Umgeknickte Ecke: Dreieck in Akzentblau
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: dx + dw - fold, y: dy + dh))
    flap.addLine(to: CGPoint(x: dx + dw, y: dy + dh - fold))
    flap.addLine(to: CGPoint(x: dx + dw - fold, y: dy + dh - fold))
    flap.closeSubpath()
    ctx.setFillColor(bottom)
    ctx.addPath(flap)
    ctx.fillPath()

    // Drei Textzeilen
    ctx.setFillColor(CGColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 1))
    let lineH = s * 0.032
    let lines: [(CGFloat, CGFloat)] = [
        (dy + dh * 0.62, dw * 0.64),
        (dy + dh * 0.47, dw * 0.64),
        (dy + dh * 0.32, dw * 0.42),
    ]
    for (yy, w) in lines {
        let line = CGPath(roundedRect: CGRect(x: dx + dw * 0.18, y: yy, width: w, height: lineH),
                          cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil)
        ctx.addPath(line)
        ctx.fillPath()
    }

    guard let img = ctx.makeImage() else {
        throw NSError(domain: "pless.icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "makeImage fehlgeschlagen"])
    }
    let dest = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "pless.icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "kein PNG-Destination"])
    }
    CGImageDestinationAddImage(out, img, nil)
    guard CGImageDestinationFinalize(out) else {
        throw NSError(domain: "pless.icon", code: 5, userInfo: [NSLocalizedDescriptionKey: "PNG-Finalize fehlgeschlagen"])
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes { try render(size: size, to: name) }
print("iconset fertig: \(outDir) (\(sizes.count) PNGs)")
