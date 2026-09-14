#!/usr/bin/env swift
// Draw bundle/AppIcon.iconset — the ten PNGs iconutil compiles into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// Both this script and the PNGs it writes are committed. The PNGs so that scripts/bundle.sh
// never has to run a Swift compiler to assemble a bundle; the script so that the artwork has a
// source, is reviewable as a diff, and can be regenerated when a colour or a proportion is wrong.
// Ten PNGs rather than one hand-assembled .icns for the same reason the rest of this repo prefers
// a check that fails loudly: iconutil rejects a member that is misnamed or the wrong size, while
// an .icns missing its 512@2x member produces a blurry Dock icon and no error anywhere.
//
// No SF Symbols. Apple's SF Symbols licence forbids their use in app icons, so every shape here
// is a CGPath. No third-party dependency either — AppKit and CoreGraphics ship with macOS, which
// is the same rule the product itself follows.
//
// Drawn at every pixel size rather than downscaled from 1024: at 16 and 32 pixels a downscale
// turns the stroke weights to mush, and the whole point of the small members is that they were
// looked at.
//
// Geometry is written in the 1024-pixel grid Apple's macOS icon template uses: a 824x824 body
// centred in a 1024 canvas, which leaves the 100-pixel margin the system expects for the shadow
// and for alignment with every other icon in the Dock.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("bundle/AppIcon.iconset")

// MARK: - Shapes

/// The rounded-square body, as a superellipse rather than a circular rounded rect.
///
/// `NSBezierPath(roundedRect:)` rounds with circular arcs, which meets the straight edge at a
/// visible kink — next to any system icon in the Dock it reads as slightly wrong without the
/// viewer being able to say why. A superellipse has continuous curvature, which is what Apple's
/// shape approximates; n = 5 is the exponent that matches it closely enough that the difference
/// is under a pixel at 1024.
func superellipse(center: CGPoint, half: CGFloat, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        // |x|^n + |y|^n = 1, parameterised so the sign of each axis follows the angle.
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: center.x + x * half, y: center.y + y * half)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - The drawing, in the 1024 grid

let canvas: CGFloat = 1024
let bodyHalf: CGFloat = 412            // 824 across, the template's body size
let bodyCenter = CGPoint(x: 512, y: 512)

/// What changes with the size, and why anything has to.
///
/// The shapes are described once in the 1024 grid and scaled, which is right for the areas and
/// wrong for the *lines*. The cradle's 46-unit stroke is 5.75 px at 128 and **0.72 px at 16** —
/// below one pixel, so it renders as a grey smear rather than a line, and at 16 the mark stopped
/// reading as a microphone at all. Measured on the first iconset: the 16 and 32 members lost the
/// cradle entirely. That size is the one in System Settings ▸ Login Items and in ⌘Tab, which is
/// exactly where someone is asking "what is this?".
///
/// So the strokes are given a floor in *rendered pixels* and converted back into grid units. This
/// is what "design each size separately" means in practice; the silhouette does not change, the
/// pen does. The two decorations go the other way: a shadow and a one-pixel highlight are detail
/// at 512 and dirt at 16, where they only soften the edge the glyph needs.
/// Thickening the pen was not enough on its own, and the measurement is worth keeping: at 16 the
/// cradle's lower arc, the stem and the stand's bar all land inside about four pixels of height,
/// so a heavier pen made them *merge* rather than resolve — two horizontal bars and a smear. Three
/// candidates were rendered at 10× and compared; dropping the stand bar at 16 was the only one
/// that still read as a microphone (dropping the cradle instead reads as an exclamation mark).
/// So 16 keeps the capsule and the cradle, and nothing else. 32 and up are unchanged.
struct Weights {
    let stroke: CGFloat       // grid units: cradle, stem, and the stand's thickness
    let stand: Bool           // the stand's bar. False only at 16, where it has nowhere to go
    let shadow: Bool
    let highlight: Bool
}

func weights(forPixels px: CGFloat) -> Weights {
    let scale = px / canvas
    /// `nominal` unless that renders thinner than `minPx`, in which case whatever does.
    func floored(_ nominal: CGFloat, _ minPx: CGFloat) -> CGFloat {
        max(nominal, minPx / scale)
    }
    switch px {
    case ...16: return Weights(stroke: floored(46, 1.5), stand: false, shadow: false, highlight: false)
    case ...32: return Weights(stroke: floored(46, 2.0), stand: true,  shadow: false, highlight: false)
    case ...64: return Weights(stroke: floored(46, 3.0), stand: true,  shadow: true,  highlight: false)
    default:    return Weights(stroke: 46, stand: true, shadow: true, highlight: true)
    }
}

/// A microphone: capsule, the cradle arc under it, a short stem, and the stand's bar.
///
/// Four shapes and no more. A fifth — a pin, a peg, a badge — is legible at 512 and is mud at 16,
/// and the 16-pixel member is the one that appears in the menu bar's app switcher and in System
/// Settings' Login Items list, which is where a user most needs to recognise it.
func drawMicrophone(_ ctx: CGContext, _ w: Weights) {
    ctx.saveGState()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)

    // The glyph spans y 190...800, whose midpoint is 495; the body's is 512. Lifting it by the
    // difference centres the mark optically rather than leaving it sitting low.
    ctx.translateBy(x: 0, y: 17)

    // Capsule. A filled area, not a line: it survives the scale down on its own, and thickening
    // it with the strokes would close the gap between it and the cradle.
    let capsule = CGRect(x: 512 - 100, y: 450, width: 200, height: 350)
    ctx.addPath(roundedRect(capsule, radius: 100))
    ctx.fillPath()

    // Cradle: the lower half of a circle, stroked. Round caps so the ends read as the same
    // drawing tool as the capsule rather than as cut tubing.
    ctx.setLineWidth(w.stroke)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: 512, y: 490), radius: 180,
               startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()

    // Stem and stand, both held to the same pen. Anchored on the stand's centre line at y = 213
    // rather than on its lower edge, so a thicker pen grows the bar symmetrically instead of
    // walking the whole glyph down out of its optical centre.
    //
    // Without a stand to reach, the stem stops just below the cradle instead of hanging in space.
    let half = w.stroke / 2
    let stemBottom: CGFloat = w.stand ? 213 - half : 300
    ctx.addPath(roundedRect(CGRect(x: 512 - half, y: stemBottom,
                                   width: w.stroke, height: 330 - stemBottom),
                            radius: half))
    ctx.fillPath()
    if w.stand {
        ctx.addPath(roundedRect(CGRect(x: 512 - 120, y: 213 - half, width: 240, height: w.stroke),
                                radius: half))
        ctx.fillPath()
    }

    ctx.restoreGState()
}

func drawIcon(into ctx: CGContext, pixels: CGFloat) {
    let w = weights(forPixels: pixels)
    let scale = pixels / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let body = superellipse(center: bodyCenter, half: bodyHalf)

    // The shadow belongs to the body, so it is set before the fill and cleared before anything is
    // drawn on top — otherwise the glyph casts one too and the mark looks embossed.
    if w.shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(body)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Blue to indigo, top to bottom. Blue because the mark has to sit in a Dock beside every
    // other utility without claiming to be an alert, and because the input meter's tint is the
    // system accent — nothing here should compete with that.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [NSColor(srgbRed: 0.36, green: 0.61, blue: 1.00, alpha: 1).cgColor,
                                       NSColor(srgbRed: 0.23, green: 0.18, blue: 0.79, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])

    // A hairline of white along the top edge. It is what stops a flat gradient from reading as a
    // rectangle of colour with a picture on it; the system's own icons all have some version of it.
    if w.highlight {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(6)
        ctx.addPath(body)
        ctx.strokePath()
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    drawMicrophone(ctx, w)
    ctx.restoreGState()
}

// MARK: - Writing the iconset

/// Every member iconutil expects, and nothing else: it fails on an unknown file, which is the
/// property this directory is chosen for.
let members: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for member in members {
    let px = member.pixels
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("error: could not create a \(px)px context\n".utf8))
        exit(1)
    }
    drawIcon(into: ctx, pixels: CGFloat(px))
    guard let image = ctx.makeImage() else {
        FileHandle.standardError.write(Data("error: could not render \(member.name)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("error: could not encode \(member.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(member.name))
    print("wrote bundle/AppIcon.iconset/\(member.name) (\(px)x\(px))")
}
