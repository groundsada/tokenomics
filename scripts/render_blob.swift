import AppKit
import Foundation

// usage: makeblob <esnet|lbl|cborg> <up:1|0> <amount> <outpath> [logoPath]
// colored pill (green/red) with logo + bold $ amount, sized for the macOS menu bar.
// If no logo path is given (or the file is missing), a plain circle with the
// mode initial is drawn instead — the repo ships with NO brand logos on purpose
// (see assets/README.md: fetch/authorize your own).
let a = CommandLine.arguments
let mode = a.count > 1 ? a[1] : "esnet"
let up   = a.count > 2 ? (a[2] == "1") : false
let amt  = a.count > 3 ? a[3] : ""
let out  = a.count > 4 ? a[4] : "/tmp/vpn_blob.png"
let fallbackLogo = mode == "lbl"
    ? FileManager.default.homeDirectoryForCurrentUser.path + "/.hermes/assets/lbl_logo.png"
    : FileManager.default.homeDirectoryForCurrentUser.path + "/.hermes/assets/esnet_logo.png"
let logoPath = a.count > 5 ? a[5] : fallbackLogo

let logo = NSImage(contentsOfFile: logoPath)

let H: CGFloat = 22
let pad: CGFloat = 4
let gap: CGFloat = 4
let radius: CGFloat = 11
let icon: CGFloat = 16
let box: CGFloat = H - 8
let ratio: CGFloat = logo.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.0 } ?? 1.0
let logoW: CGFloat = mode == "lbl" ? min(box * ratio, 26) : icon
let logoH: CGFloat = mode == "lbl" ? min(box, box * ratio) : icon

let font = NSFont.boldSystemFont(ofSize: 14)
let attr: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: amt, attributes: attr)
let ts = str.size()
let W = pad + logoW + gap + ts.width + pad + 2

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let pill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H),
                        xRadius: radius, yRadius: radius)
let fill = up ? NSColor(calibratedRed: 0.06, green: 0.62, blue: 0.22, alpha: 1.0)
              : NSColor(calibratedRed: 0.84, green: 0.13, blue: 0.11, alpha: 1.0)
fill.setFill()
pill.fill()
NSColor(calibratedWhite: 0.0, alpha: 0.45).setStroke()
pill.lineWidth = 1.0
pill.stroke()

let lx = pad
let ly = (H - logoH) / 2
let lrect = NSRect(x: lx, y: ly, width: logoW, height: logoH)

if let logo = logo {
    if mode == "lbl" {
        logo.draw(in: lrect, from: .zero, operation: .sourceOver, fraction: 1.0)
    } else {
        let circleClip = NSBezierPath(ovalIn: NSRect(x: lx, y: ly, width: icon, height: icon))
        NSGraphicsContext.current?.saveGraphicsState()
        circleClip.addClip()
        logo.draw(in: NSRect(x: lx, y: ly, width: icon, height: icon),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
} else {
    // fallback: neutral circle with the mode initial, in case no logo is provided
    let letter = (mode == "lbl" ? "L" : (mode == "cborg" ? "C" : "E")) as NSString
    let fattr: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 11),
        .foregroundColor: NSColor.white,
    ]
    let sz = letter.size(withAttributes: fattr)
    letter.draw(at: NSPoint(x: lx + (icon - sz.width) / 2, y: ly + (icon - sz.height) / 2),
                withAttributes: fattr)
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
