import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "/tmp/dmg-bg.png"
let W: CGFloat = 660, H: CGFloat = 400
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1),
])!
grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

let title = NSAttributedString(string: "VPNStatusBar", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1),
])
let ts = title.size()
title.draw(at: NSPoint(x: (W - ts.width)/2, y: H - 70))

let sub = NSAttributedString(string: "中唐 VPN 状态栏工具 · 拖入 Applications 完成安装", attributes: [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.40, alpha: 1),
])
let ss = sub.size()
sub.draw(at: NSPoint(x: (W - ss.width)/2, y: H - 100))

let hint = NSAttributedString(string: "首次打开如提示“无法验证开发者”：右键 → 打开（详见 DMG 内《打开指引.html》）", attributes: [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.60, alpha: 1),
])
let hs = hint.size()
hint.draw(at: NSPoint(x: (W - hs.width)/2, y: 28))

func rounded(_ rect: NSRect, _ fill: NSColor, _ stroke: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
    fill.setFill(); path.fill()
    stroke.setStroke(); path.lineWidth = 1.5; path.stroke()
}
let boxW: CGFloat = 130, boxH: CGFloat = 130
let yBox: CGFloat = 110
rounded(NSRect(x: 120, y: yBox, width: boxW, height: boxH),
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.85),
        NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.85, alpha: 1))
rounded(NSRect(x: W - 120 - boxW, y: yBox, width: boxW, height: boxH),
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.85),
        NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.85, alpha: 1))

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("OK")
