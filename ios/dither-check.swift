// D55 guard: the wave lives in the 10 pt gutter around the panel, so the outer
// few percent of a screenshot must not be one flat colour. v18 and v19 both
// shipped with no dither at all because an opaque tab background covered it,
// and nothing in CI noticed — three builds of flat screenshots.
//
// usage: swift dither-check.swift screens/chats.png [...]
//
// Exit 1 (with the colour count) when a border reads as a single colour.

import Foundation
import CoreGraphics
import ImageIO

func rgbFrequencies(path: String) -> (Int, Int) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("dither-check: cannot read \(path)")
        exit(2)
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("dither-check: cannot make a bitmap for \(path)")
        exit(2)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // The gutter is 10 pt: ~2.5 % of the width at any scale. Sample a little
    // more than that on both edges, skipping the status bar and the tab bar.
    let band = max(2, Int(Double(width) * 0.025))
    let firstRow = Int(Double(height) * 0.25)
    let lastRow = Int(Double(height) * 0.75)
    var seen = Set<UInt32>()
    var y = firstRow
    while y < lastRow {
        for x in 0..<band {
            let i = (y * width + x) * 4
            seen.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
        for x in (width - band)..<width {
            let i = (y * width + x) * 4
            seen.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
        y += 2
    }
    return (seen.count, width)
}

var failed: [String] = []
for path in CommandLine.arguments.dropFirst() {
    let (colours, width) = rgbFrequencies(path: path)
    print("dither-check: \(path) (\(width) px wide) gutter colours = \(colours)")
    // Three tones is the least a dithered band can show; a covered wave shows 1.
    if colours < 3 { failed.append(path) }
}

if !failed.isEmpty {
    print("dither-check: no dither in \(failed.joined(separator: ", ")) — something opaque is over the wave (see docs/DECISIONS.md D55)")
    exit(1)
}
