// Baut das pless-App-Icon aus einem vorhandenen Bild (z. B. docs/pless-icon.jpg):
// Quadrat-Crop (mittig, aspect-fill) und Rendern aller iconset-Größen als PNG.
// Nutzung: swift Scripts/make-icon-from-image.swift <quelle.jpg|png> <ziel-iconset-dir>
// Danach: iconutil -c icns <iconset-dir> -o pless.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count > 2 else {
    FileHandle.standardError.write(Data("Nutzung: make-icon-from-image.swift <quelle> <iconset-dir>\n".utf8))
    exit(1)
}
let srcURL = URL(fileURLWithPath: args[1])
let outDir = args[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("Bild konnte nicht geladen werden: \(srcURL.path)\n".utf8))
    exit(1)
}
let srcW = CGFloat(img.width), srcH = CGFloat(img.height)
// mittiger Quadrat-Crop
let side = min(srcW, srcH)
let cropRect = CGRect(x: (srcW - side) / 2, y: (srcH - side) / 2, width: side, height: side)

func render(size: Int, to name: String) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "pless.icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein CGContext"])
    }
    ctx.interpolationQuality = .high
    // mittiger Quadrat-Crop (aspect-fill), Quelle AUFRECHT zeichnen (kein y-Flip —
    // CGContext.draw bildet das Bild sonst kopfüber in die PNG ab)
    let scale = CGFloat(size) / side
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    ctx.translateBy(x: -cropRect.minX * scale, y: -cropRect.minY * scale)
    ctx.scaleBy(x: scale, y: scale)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
    ctx.restoreGState()

    guard let out = ctx.makeImage() else {
        throw NSError(domain: "pless.icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "makeImage fehlgeschlagen"])
    }
    let dest = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "pless.icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "kein PNG-Destination"])
    }
    CGImageDestinationAddImage(dst, out, nil)
    guard CGImageDestinationFinalize(dst) else {
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
print("iconset aus Bild fertig: \(outDir) (\(sizes.count) PNGs)")
