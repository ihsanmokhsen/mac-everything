// Menggambar ikon mac-everything ke AppIcon.iconset: tulisan EVERYTHING hitam tebal-lebar
// di atas latar abu-abu muda. Hurufnya memakai font sistem macOS.  Jalankan lewat makeicon.sh
import AppKit

let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Latar: kotak membulat gaya macOS, abu-abu muda.
let box = NSRect(x: 100, y: 100, width: 824, height: 824)
NSColor(white: 0.91, alpha: 1).setFill()
NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185).fill()

// Tulisan: font sistem, berat heavy, lebar expanded; ukurannya dicari agar pas selebar kotak.
let text = "EVERYTHING"
let target: CGFloat = 700
func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: size, weight: .heavy, width: .expanded),
     .foregroundColor: NSColor(white: 0.07, alpha: 1),
     .kern: size * 0.02]
}
var size: CGFloat = 100
let w100 = (text as NSString).size(withAttributes: attrs(size)).width
size = size * target / w100
let a = attrs(size)
let ts = (text as NSString).size(withAttributes: a)
let font = a[.font] as! NSFont
// Pusatkan menurut tinggi huruf kapital, bukan kotak baris.
let baseline = box.midY - font.capHeight / 2
(text as NSString).draw(at: NSPoint(x: box.midX - ts.width / 2, y: baseline + font.descender), withAttributes: a)

NSGraphicsContext.current?.flushGraphics()
let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/icon_512x512@2x.png"))
