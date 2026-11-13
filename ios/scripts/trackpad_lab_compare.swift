// Compares Trackpad Lab's recorded frames with the stored ones (ios/scripts/trackpad_lab_frames.sh).
// Pass: 99.5 % of pixels within 4/255 in each channel. A frame with no stored copy becomes the stored copy.
// Usage: xcrun swift trackpad_lab_compare.swift <frames dir> <reference dir>
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ url: URL) -> (Int, Int, [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: trackpad_lab_compare.swift <frames> <reference>"); exit(2) }
let frames = URL(fileURLWithPath: args[1]), ref = URL(fileURLWithPath: args[2])
let fm = FileManager.default
let names = (try? fm.contentsOfDirectory(atPath: frames.path))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
var failed = 0, stored = 0, passed = 0
for n in names {
    let a = frames.appendingPathComponent(n), b = ref.appendingPathComponent(n)
    guard fm.fileExists(atPath: b.path) else {
        try? fm.copyItem(at: a, to: b)
        stored += 1
        continue
    }
    guard let (w1, h1, p1) = pixels(a), let (w2, h2, p2) = pixels(b), w1 == w2, h1 == h2 else {
        print("FAIL \(n): size differs or unreadable")
        failed += 1
        continue
    }
    var off = 0
    for i in stride(from: 0, to: p1.count, by: 4) {
        if abs(Int(p1[i]) - Int(p2[i])) > 4 || abs(Int(p1[i + 1]) - Int(p2[i + 1])) > 4 || abs(Int(p1[i + 2]) - Int(p2[i + 2])) > 4 { off += 1 }
    }
    let share = 1 - Double(off) / Double(w1 * h1)
    if share >= 0.995 { passed += 1 } else {
        print(String(format: "FAIL %@: %.3f %% of pixels within 4/255", n, share * 100))
        failed += 1
    }
}
print("frames: \(passed) match, \(failed) differ, \(stored) stored as new references")
exit(failed > 0 ? 1 : 0)
