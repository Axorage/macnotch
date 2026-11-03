// Derives a macOS-26-friendly icon set from Resources/AppIcon.png (source is never modified).
// usage: swift scripts/make-icon.swift <source.png> <out.iconset> [full|grid]
// full: opaque full-bleed square (system applies its own squircle mask)
// grid: 824pt squircle-ish artwork centred in 1024 with transparent margin
import AppKit
let a = CommandLine.arguments
let mode = a.count > 3 ? a[3] : "full"
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let W = src.pixelsWide, H = src.pixelsHigh
// Pull source into a known RGBA8 buffer.
var buf = [UInt8](repeating: 0, count: W*H*4)
let sctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sctx.draw(src.cgImage!, in: CGRect(x: 0, y: 0, width: W, height: H))
func alpha(_ x: Int,_ y: Int)->UInt8 { buf[(y*W+x)*4+3] }
// Opaque bounding box.
var x0=W,x1=0,y0=H,y1=0
for y in 0..<H { for x in 0..<W where alpha(x,y) > 200 { x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y) } }
// Square crop slightly inside the artwork's edge (drops the soft rim/shadow).
let inset = 12
let side = min(x1-x0, y1-y0) - 2*inset
let cx = (x0+x1)/2, cy = (y0+y1)/2
let cropX = cx - side/2, cropY = cy - side/2
// Build opaque square: row-wise edge extension fills the rounded corners.
var sq = [UInt8](repeating: 255, count: side*side*4)
for y in 0..<side {
  let sy = cropY + y
  var l = -1, r = -1
  for x in 0..<side where alpha(cropX+x, sy) > 250 { if l < 0 { l = x }; r = x }
  if l < 0 { l = side/2; r = l }
  for x in 0..<side {
    let sx = x < l ? cropX+l : (x > r ? cropX+r : cropX+x)
    let i = (sy*W+sx)*4, o = (y*side+x)*4
    let al = Double(buf[i+3])/255
    // un-premultiply then force opaque
    for c in 0..<3 { o_set(&sq, o+c, al > 0 ? min(255, Double(buf[i+c])/al) : 0) }
  }
}
func o_set(_ b: inout [UInt8], _ i: Int, _ v: Double) { b[i] = UInt8(max(0, min(255, v))) }
let sqImg = CGContext(data: &sq, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side*4,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let g = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
  g.cgContext.interpolationQuality = .high
  let s = CGFloat(px)
  if mode == "grid" {
    let d = s*824/1024, rect = CGRect(x:(s-d)/2, y:(s-d)/2, width:d, height:d)
    // Apple-like continuous corner radius ~ 22.37% of side
    NSBezierPath(roundedRect: rect, xRadius: d*0.2237, yRadius: d*0.2237).addClip()
    g.cgContext.draw(sqImg, in: rect)
  } else {
    g.cgContext.draw(sqImg, in: CGRect(x:0,y:0,width:s,height:s))
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
for sz in [16,32,128,256,512] {
  try! render(sz).write(to: URL(fileURLWithPath: "\(a[2])/icon_\(sz)x\(sz).png"))
  try! render(sz*2).write(to: URL(fileURLWithPath: "\(a[2])/icon_\(sz)x\(sz)@2x.png"))
}
