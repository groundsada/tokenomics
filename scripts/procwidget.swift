import AppKit
import Foundation

// procwidget.swift — native NSStatusItem menubar app: RAM/CPU hog detector.
// Pill = makeblob mem <0|1|2> "<gb>G <name>" (same renderer as the VPN widget).
// Menu = RAM summary / Ask Hermes / Activity Monitor / top consumers / refresh.
// Zero dependencies: probe is the same zero-LLM proc_probe.py the agent uses.

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let PROBE = HOME + "/.hermes/scripts/proc_probe.py"
let MAKEBLOB = HOME + "/.hermes/assets/makeblob"
let SNAPPATH = HOME + "/.hermes/state/proc_snap.json"
let BLOBPATH = "/tmp/proc_blob.png"
let PROMPTPATH = "/tmp/proc_prompt.txt"

func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-lc", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

func loadJSON() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: SNAPPATH),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

final class ProcApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem? = nil   // created on demand (remove/re-add = reliable show/hide)
    var snap: [String: Any] = [:]
    var lastAI = ""
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.refresh() }
        timer?.tolerance = 5
    }

    func ensureItem() -> NSStatusItem {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageOnly
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        return statusItem!
    }

    func dropItem() {
        if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
            statusItem = nil
        }
    }

    // "things start to hang" ≈ memory squeeze, not just a normal day
    func trigger() -> Bool {
        let used = snap["used_pct"] as? Double ?? 0
        let total = snap["total_gb"] as? Double ?? 48
        let comp = snap["compressed_gb"] as? Double ?? 0
        let top = snap["top"] as? [[String: Any]]
        let topG = ((top?.first?["footprint_gb"] as? Double) ?? (top?.first?["mem_gb"] as? Double)) ?? 0
        return used >= 85 || topG >= 0.2 * total || comp >= 0.5 * total
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            _ = shell("\(PROBE) >/dev/null 2>&1")
            let d = loadJSON()
            DispatchQueue.main.async {
                self.snap = d
                let force = ProcessInfo.processInfo.environment["PROCWIDGET_FORCE_SHOW"] == "1"
                if self.trigger() || force {
                    let _ = self.ensureItem()
                    self.renderPill()
                } else {
                    self.dropItem()
                }
            }
        }
    }

    // keep the pill ~126px like the VPN pill: short name only (long ones overlap/cover neighbors)
    func shortPillName(_ raw: String) -> String {
        var n = raw
        for p in ["python -m ", "python3.12 ", "python3.13 ", "java ", "/"] {
            n = n.replacingOccurrences(of: p, with: "")
        }
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if let last = n.split(separator: " ").last { n = String(last) }
        return String(n.prefix(9))
    }

    func renderPill() {
        let lvl = (snap["level"] as? String) ?? "ok"
        let st = lvl == "bad" ? "2" : (lvl == "watch" ? "1" : "0")
        let top = snap["top"] as? [[String: Any]]
        var gb = 0.0
        var nm = "?"
        if let t = top?.first {
            gb = ((t["footprint_gb"] as? Double) ?? (t["mem_gb"] as? Double)) ?? 0
            nm = shortPillName((t["name"] as? String) ?? "?")
        }
        let gbs = gb >= 10 ? String(format: "%.0fG", gb) : String(format: "%.1fG", gb)
        let amt = gbs + " " + nm
        DispatchQueue.global(qos: .utility).async {
            _ = shell("'\(MAKEBLOB)' mem \(st) '\(amt)' '\(BLOBPATH)'")
            guard let img = NSImage(contentsOfFile: BLOBPATH) else { return }
            DispatchQueue.main.async {
                let it = self.statusItem
                it?.button?.image = img
                it?.button?.toolTip = (self.snap["verdict"] as? String) ?? ""
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let used = snap["used_pct"] as? Double ?? 0
        let free = snap["free_gb"] as? Double ?? 0
        let comp = snap["compressed_gb"] as? Double ?? 0
        menu.addItem(NSMenuItem(title: String(format: "RAM %.0f%% used · %.1fG free · %.1fG compressed", used, free, comp), action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let ask = NSMenuItem(title: "Ask Hermes: what's using RAM?", action: #selector(askHermes), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivity), keyEquivalent: "")
        am.target = self
        menu.addItem(am)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Top consumers (click = copy cmd)", action: nil, keyEquivalent: ""))

        if let top = snap["top"] as? [[String: Any]] {
            for t in top.prefix(6) {
                let gb = (t["footprint_gb"] as? Double) ?? (t["mem_gb"] as? Double) ?? 0
                let cpu = t["cpu"] as? Double ?? 0
                let name = (t["name"] as? String) ?? "?"
                let et = (t["etime"] as? String) ?? ""
                let row = NSMenuItem(title: String(format: "  %.1fG %4.0f%%  %@%@", gb, cpu, name, shortUptime(et)), action: #selector(copyCmd(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = t["full_cmd"] ?? t["name"]
                menu.addItem(row)
            }
        }

        if !lastAI.isEmpty {
            menu.addItem(.separator())
            let v = NSMenuItem(title: "Last AI: " + lastAI.replacingOccurrences(of: "\n", with: " "), action: nil, keyEquivalent: "")
            v.isEnabled = false
            menu.addItem(v)
        }

        menu.addItem(.separator())
        let rf = NSMenuItem(title: "Refresh", action: #selector(refreshClick), keyEquivalent: "")
        rf.target = self
        menu.addItem(rf)
    }

    func shortUptime(_ et: String) -> String {
        let p = et.split(separator: "-")
        if p.count == 2 { return "  up \(p[0])d\(String(p[1]).split(separator: ":")[0])h" }
        if !et.isEmpty { return "  up \(et)" }
        return ""
    }

    @objc func copyCmd(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        statusItem?.button?.toolTip = "Copied: " + cmd.prefix(80)
        NSSound.beep()
    }

    @objc func openActivity() { NSWorkspace.shared.launchApplication("Activity Monitor") }
    @objc func refreshClick() { refresh() }

    @objc func askHermes() {
        let verdict = (snap["verdict"] as? String) ?? "no verdict"
        let prompt = "You are a macOS RAM/CPU analyzer on a Mac. Use the macos-app-recovery memory-hog procedure (footprint incl compressed, idle+zero-clients = safe kill). Data:\n" + verdict + "\nTop:\n" + jsonLineSummary() + "\nIdentify the likely hog, evidence in 1-2 lines, is it SAFE to kill, and give the exact kill + restart command. Max 6 lines."
        try? prompt.write(toFile: PROMPTPATH, atomically: true, encoding: .utf8)
        statusItem?.button?.toolTip = "analyzing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let out = shell("hermes chat -q \"$(cat \(PROMPTPATH))\" -s macos-app-recovery --cli 2>&1")
            let ans = Self.parseAnswer(out)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(ans, forType: .string)
            DispatchQueue.main.async {
                self.lastAI = ans
                self.statusItem?.button?.toolTip = ans
                NSSound.beep()
                if let m = self.statusItem?.menu { self.menuNeedsUpdate(m) }
            }
        }
    }

    func jsonLineSummary() -> String {
        guard let top = snap["top"] as? [[String: Any]] else { return "" }
        var s = ""
        for t in top.prefix(5) {
            let gb = (t["footprint_gb"] as? Double) ?? (t["mem_gb"] as? Double) ?? 0
            let cpu = t["cpu"] as? Double ?? 0
            s += String(format: "- %@ (pid %@) %.1fG cpu %.0f%% up %@ clients %@ :: %@\n",
                (t["name"] as? String) ?? "?", "\(t["pid"] ?? "?")", gb, cpu,
                (t["etime"] as? String) ?? "?", "\(t["clients"] ?? "?")",
                ((t["full_cmd"] as? String) ?? "").prefix(90).description)
        }
        return s
    }

    // Extract the LAST "⚕ Hermes" answer box from `hermes chat -q` CLI output.
    static func parseAnswer(_ raw: String) -> String {
        let s = (raw as NSString).replacingOccurrences(of: "\r", with: "")
        let ns = s as NSString
        var last = NSRange(location: NSNotFound, length: 0)
        var loc = 0
        while loc <= ns.length {
            let r = ns.range(of: "⚕ Hermes", options: [], range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            last = r
            loc = r.location + r.length
        }
        if last.location == NSNotFound {
            let sr = ns.range(of: "Session:")
            if sr.location != NSNotFound {
                return ns.substring(to: sr.location).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyStart = last.location + last.length
        let cr = ns.range(of: "╰", options: [], range: NSRange(location: bodyStart, length: ns.length - bodyStart))
        if cr.location == NSNotFound {
            return ns.substring(from: bodyStart).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var body = ns.substring(with: NSRange(location: bodyStart, length: cr.location - bodyStart))
        if let nl = body.range(of: "\n") { body = String(body[nl.upperBound...]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let app = NSApplication.shared
let delegate = ProcApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
