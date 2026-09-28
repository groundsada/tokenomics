import AppKit
import Foundation

// usage: makeblob <esnet|lbl|mem> <state> <amount> <outpath>
// colored pill (green/red) with logo + bold amount.
// mem mode: state 0=ok(green) 1=watch(amber) 2=bad(red); draws an "M" chip,
//           no logo file needed.  Sized for the menu bar: H=22pt (44px @2x).
let a = CommandLine.arguments
let mode = a.count > 1 ? a[1] : "esnet"
let stateVal = a.count > 2 ? a[2] : "0"
let amt  = a.count > 3 ? a[3] : ""
let out  = a.count > 4 ? a[4] : "/tmp/vpn_blob.png"

let home = FileManager.default.homeDirectoryForCurrentUser.path
let logoPath = mode == "lbl" ? home + "/.hermes/assets/lbl_logo.png"
                             : home + "/.hermes/assets/esnet_logo.png"

let H: CGFloat = 22          // pill height in points (44px @2x)
let pad: CGFloat = 4
let gap: CGFloat = 4
let radius: CGFloat = 11
let icon: CGFloat = 16       // orb/"M" circle size
let box: CGFloat = H - 8     // 14 — logo clearance
var logoW: CGFloat = icon
var logoH: CGFloat = icon
var logo: NSImage? = nil

if mode == "mem" {
    logo = nil
} else {
    guard let l = NSImage(contentsOfFile: logoPath) else {
        fputs("cannot load logo\n", stderr); exit(1)
    }
    logo = l
    let ratio = l.size.height > 0 ? l.size.width / l.size.height : 1.0
    logoW = mode == "lbl" ? min(box * ratio, 26) : icon
    logoH = mode == "lbl" ? min(box, box * ratio) : icon
}

let font = NSFont.boldSystemFont(ofSize: 14)
let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let str = NSAttributedString(string: amt, attributes: attr)
let ts = str.size()
let W = pad + logoW + gap + ts.width + pad + 2

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let pill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H),
                        xRadius: radius, yRadius: radius)
let fill: NSColor
if mode == "mem" {
    fill = stateVal == "2" ? NSColor(calibratedRed: 0.84, green: 0.13, blue: 0.11, alpha: 1.0)
         : stateVal == "1" ? NSColor(calibratedRed: 0.86, green: 0.55, blue: 0.05, alpha: 1.0)
         : NSColor(calibratedRed: 0.06, green: 0.62, blue: 0.22, alpha: 1.0)
} else {
    fill = stateVal == "1" ? NSColor(calibratedRed: 0.06, green: 0.62, blue: 0.22, alpha: 1.0)
         : NSColor(calibratedRed: 0.84, green: 0.13, blue: 0.11, alpha: 1.0)
}
fill.setFill()
pill.fill()
NSColor(calibratedWhite: 0.0, alpha: 0.45).setStroke()
pill.lineWidth = 1.0
pill.stroke()

let lx = pad
let ly = (H - logoH) / 2
if mode == "mem" {
    // white "M" chip circle (memory) - no logo file required
    let letter = "M" as NSString
    let fattr: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 12),
        .foregroundColor: NSColor.white,
    ]
    let sz = letter.size(withAttributes: fattr)
    letter.draw(at: NSPoint(x: lx + (icon - sz.width) / 2, y: ly + (icon - sz.height) / 2),
                withAttributes: fattr)
} else if let logo = logo {
    if mode == "lbl" {
        logo.draw(in: NSRect(x: lx, y: ly, width: logoW, height: logoH),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
    } else {
        let circleClip = NSBezierPath(ovalIn: NSRect(x: lx, y: ly, width: icon, height: icon))
        NSGraphicsContext.current?.saveGraphicsState()
        circleClip.addClip()
        logo.draw(in: NSRect(x: lx, y: ly, width: icon, height: icon),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

let tx = lx + logoW + gap
str.draw(at: NSPoint(x: tx, y: (H - ts.height) / 2 - 0.5))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr); exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
