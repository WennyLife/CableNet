import AppKit
let destination = CommandLine.arguments[1]
for pixels in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels)/1024); transform.concat()
    let surface = NSBezierPath(roundedRect: NSRect(x: 30,y: 30,width: 964,height: 964),xRadius: 215,yRadius: 215)
    NSGradient(starting: NSColor(srgbRed: 0.10,green: 0.17,blue: 0.25,alpha: 1),ending: NSColor(srgbRed: 0.03,green: 0.07,blue: 0.13,alpha: 1))!.draw(in: surface, angle: -90)
    let green = NSColor(srgbRed: 0.24,green: 0.87,blue: 0.47,alpha: 1)
    let wire = NSBezierPath(); wire.move(to: NSPoint(x: 490,y: 330)); wire.line(to: NSPoint(x: 490,y: 235)); wire.curve(to: NSPoint(x: 755,y: 175),controlPoint1: NSPoint(x: 490,y: 105),controlPoint2: NSPoint(x: 650,y: 175)); wire.lineWidth = 55; wire.lineCapStyle = .round; green.setStroke(); wire.stroke()
    green.setFill(); NSBezierPath(roundedRect: NSRect(x: 290,y: 315,width: 415,height: 345),xRadius: 65,yRadius: 65).fill(); NSBezierPath(roundedRect: NSRect(x: 385,y: 660,width: 220,height: 70),xRadius: 20,yRadius: 20).fill()
    NSColor(srgbRed: 0.05,green: 0.17,blue: 0.14,alpha: 1).setFill()
    for x in stride(from: 345.0,through: 645.0,by: 60) { NSBezierPath(roundedRect: NSRect(x: x,y: 545,width: 22,height: 75),xRadius: 7,yRadius: 7).fill() }
    NSBezierPath(roundedRect: NSRect(x: 390,y: 365,width: 215,height: 30),xRadius: 15,yRadius: 15).fill()
    let bolt=NSBezierPath(); bolt.move(to: NSPoint(x: 760,y: 785)); for p in [NSPoint(x: 625,y: 660),NSPoint(x: 710,y: 660),NSPoint(x: 660,y: 550),NSPoint(x: 825,y: 705),NSPoint(x: 740,y: 705)]{bolt.line(to:p)}; bolt.close(); NSColor(srgbRed: 1,green: 0.82,blue: 0.21,alpha: 1).setFill(); bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    let png=rep.representation(using: .png,properties: [:])!
    let names: [String]
    switch pixels {
    case 16: names=["icon_16x16.png"]
    case 32: names=["icon_16x16@2x.png","icon_32x32.png"]
    case 64: names=["icon_32x32@2x.png"]
    case 128: names=["icon_128x128.png"]
    case 256: names=["icon_128x128@2x.png","icon_256x256.png"]
    case 512: names=["icon_256x256@2x.png","icon_512x512.png"]
    default: names=["icon_512x512@2x.png"]
    }
    for name in names { try png.write(to:URL(fileURLWithPath:destination).appendingPathComponent(name)) }
}
