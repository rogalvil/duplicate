#!/usr/bin/env swift
//
// Renders Resources/AppIcon.icns from code.
//
// Drawn rather than committed as an opaque binary so the design is reviewable in a diff and can be
// regenerated at any size. Run it after changing anything here:
//
//     make icon
//
// The resulting .icns is committed, so ordinary builds do not pay for rendering it.

import AppKit
import Foundation

/// Two overlapping rounded squares: the "this file exists twice" motif.
///
/// Deliberately plain, with exactly one idea in it. The icon has to stay legible at 16 pt in Finder,
/// in the Dock at small sizes, and in the System Settings privacy lists -- and this app will sit in
/// those lists, because reading folders is what it does. Anything with fine detail turns to mush
/// there, which is why there is no magnifying glass, no text and no gradient inside the shapes.
///
/// Verification is visual and there is no way around that: run `make icon`, then
/// `iconutil -c iconset Resources/AppIcon.icns` and look at the 16x16 PNG. A number cannot tell you
/// whether two overlapping squares still read as two squares at that size.
func drawIcon(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Background: rounded square with a slight vertical lift, so it does not look flat against a dark
    // Finder sidebar. macOS applies its own mask to app icons, but drawing the shape keeps the corners
    // consistent when the icon is shown unmasked -- as it is in the privacy lists.
    let inset = size * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.22
    context.saveGState()
    context.addPath(
        CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    )
    context.clip()
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.20, green: 0.42, blue: 0.72, alpha: 1),
                CGColor(red: 0.12, green: 0.25, blue: 0.48, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: body.maxY),
            end: CGPoint(x: 0, y: body.minY),
            options: []
        )
    }
    context.restoreGState()

    // The two sheets. The back one is dimmed and offset up-left; the front one is opaque. The offset is
    // a fixed fraction of the canvas so the pair keeps its proportion at every size.
    let sheet = size * 0.38
    let offset = size * 0.105
    let centre = CGPoint(x: body.midX, y: body.midY)
    let sheetRadius = sheet * 0.16

    func sheetPath(dx: CGFloat, dy: CGFloat) -> CGPath {
        let origin = CGPoint(x: centre.x - sheet / 2 + dx, y: centre.y - sheet / 2 + dy)
        return CGPath(
            roundedRect: CGRect(origin: origin, size: CGSize(width: sheet, height: sheet)),
            cornerWidth: sheetRadius,
            cornerHeight: sheetRadius,
            transform: nil
        )
    }

    // Back sheet, translucent white.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.62))
    context.addPath(sheetPath(dx: -offset, dy: offset))
    context.fillPath()

    // A gap punched around the front sheet, so the two shapes stay separate at 16 pt instead of
    // merging into one blob. Drawn as the background colour rather than as a stroke, because a hairline
    // stroke disappears at small sizes.
    let gap = max(size * 0.030, 1)
    context.setBlendMode(.copy)
    context.setFillColor(CGColor(red: 0.14, green: 0.29, blue: 0.55, alpha: 1))
    context.addPath(
        CGPath(
            roundedRect: CGRect(
                x: centre.x - sheet / 2 + offset - gap,
                y: centre.y - sheet / 2 - offset - gap,
                width: sheet + gap * 2,
                height: sheet + gap * 2
            ),
            cornerWidth: sheetRadius + gap,
            cornerHeight: sheetRadius + gap,
            transform: nil
        )
    )
    context.fillPath()
    context.setBlendMode(.normal)

    // Front sheet, opaque white.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    context.addPath(sheetPath(dx: offset, dy: -offset))
    context.fillPath()
}

func renderPNG(size: Int) throws -> Data {
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw Failure("cannot create a \(size)x\(size) context") }

    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage() else { throw Failure("cannot snapshot the context") }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw Failure("cannot encode PNG at \(size)x\(size)")
    }
    return data
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// The set `iconutil` expects. Every entry is drawn at its own pixel size rather than scaled from one
// master, so the gap between the two sheets is a whole pixel at 16 pt instead of a blur.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let manager = FileManager.default
let repository = URL(filePath: manager.currentDirectoryPath)
let iconset = repository.appending(path: "build/AppIcon.iconset", directoryHint: .isDirectory)
let output = repository.appending(path: "Resources/AppIcon.icns", directoryHint: .notDirectory)

try? manager.removeItem(at: iconset)
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in entries {
    let data = try renderPNG(size: entry.pixels)
    try data.write(to: iconset.appending(path: entry.name, directoryHint: .notDirectory))
}

let process = Process()
process.executableURL = URL(filePath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns", iconset.path(percentEncoded: false),
    "-o", output.path(percentEncoded: false),
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw Failure("iconutil exited \(process.terminationStatus)")
}
try? manager.removeItem(at: iconset)

let bytes = (try? manager.attributesOfItem(atPath: output.path(percentEncoded: false))[.size])
print("Wrote \(output.path(percentEncoded: false)) (\(bytes ?? 0) bytes, \(entries.count) sizes)")
print("Look at it before trusting it:")
print("  iconutil -c iconset Resources/AppIcon.icns -o /tmp/icon.iconset && open /tmp/icon.iconset")
