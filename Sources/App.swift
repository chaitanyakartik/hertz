import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model = Model()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var anim: Timer?
    private var phase: Double = 0
    private var level: Double = 0   // icon motion, eases in/out with play state
    private var panel: NSPanel?     // fallback when the icon is hidden behind the notch

    func applicationDidFinishLaunching(_ note: Notification) {
        // New status items land at the far left, behind the notch on a full menu bar. Seed a slot near
        // the system icons (points from the right edge; Sound ~208, Bluetooth ~246). ⌘-drag still moves it,
        // and macOS saves wherever it's dropped under the same key.
        let slot = "NSStatusItem Preferred Position LullIcon"   // key kept from the old name: keeps the icon where you put it
        if UserDefaults.standard.object(forKey: slot) == nil { UserDefaults.standard.set(230, forKey: slot) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "LullIcon"
        if let b = item.button {
            b.image = StatusIcon.image(phase: 0, level: 0)
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Hertz: click for controls, right-click to play/pause"
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(m: model))
        popover.appearance = NSAppearance(named: .darkAqua)   // the Glyph panel is black glass in either system mode

        model.onPlayingChange = { [weak self] _ in self?.startIconAnimation() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let f = self.item.button?.window?.frame else { return }
            NSLog("Hertz: icon at x=%.0f..%.0f hidden=%d", f.minX, f.maxX, self.iconHidden ? 1 : 0)
        }

        // First launch: if the menu bar is too full and the icon landed behind the notch, say hello anyway.
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showControls() }
        }
    }

    /// Opening Hertz again (Spotlight, Finder, Raycast) always brings up the controls.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    /// macOS silently hides status items that don't fit beside the notch.
    private var iconHidden: Bool {
        guard let w = item.button?.window, let screen = w.screen ?? NSScreen.main else { return true }
        if !w.occlusionState.contains(.visible) { return true }
        let f = w.frame
        if f.maxX <= screen.frame.minX || f.minX >= screen.frame.maxX { return true }
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let notchL = screen.frame.minX + l.maxX, notchR = screen.frame.minX + r.minX
            if f.maxX > notchL && f.minX < notchR { return true }
        }
        return false
    }

    private func showControls() {
        if !iconHidden, let b = item.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = panel ?? makePanel()
        if let screen = NSScreen.main {
            let v = screen.visibleFrame, size = p.frame.size
            p.setFrameOrigin(NSPoint(x: v.maxX - size.width - 12, y: v.maxY - size.height - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(rootView: PanelView(m: model))
        let p = NSPanel(contentViewController: host)
        p.styleMask = [.titled, .closable, .fullSizeContentView]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = .black
        p.isReleasedWhenClosed = false
        p.delegate = self
        panel = p
        return p
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)   // behaves like the popover: click away and it's gone
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            model.toggle()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let b = item.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(model.handle)
    }

    /// Bars dance while playing and settle when paused. ~20 fps, only while moving.
    private func startIconAnimation() {
        guard anim == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let target: Double = self.model.playing ? 1 : 0
            self.level += (target - self.level) * 0.12
            self.phase += 0.05 * (1.2 + pow(self.model.mode.beat, 0.5) * 0.35)
            self.item.button?.image = StatusIcon.image(phase: self.phase, level: self.level)
            if !self.model.playing && self.level < 0.01 {
                self.level = 0
                self.item.button?.image = StatusIcon.image(phase: 0, level: 0)
                timer.invalidate(); self.anim = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        anim = t
    }
}

enum StatusIcon {
    static let rest: [Double] = [0.34, 0.6, 0.92, 0.6, 0.34]

    static func image(phase: Double, level: Double) -> NSImage {
        let size = NSSize(width: 19, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let barW: CGFloat = 2.3, gap: CGFloat = 1.6
            let total = barW * 5 + gap * 4
            var x = (size.width - total) / 2
            let maxH: CGFloat = 13
            for i in 0..<5 {
                let still = rest[i] * 0.62
                let moving = rest[i] * (0.38 + 0.62 * abs(sin(phase * (1 + Double(i % 2) * 0.35) + Double(i) * 1.1)))
                let hgt = max(barW, maxH * CGFloat(still + (moving - still) * level))
                let r = NSRect(x: x, y: (size.height - hgt) / 2, width: barW, height: hgt)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// `Hertz --snapshot <dir>`: render the panel (light + dark) to PNGs for review.
/// `Hertz --record <dir>`: play a short scripted session with real audio and save the panel at 30 fps.
/// `Hertz --icon <dir>`: render the app icon iconset.
@MainActor enum Render {
    static func snapshot(to dir: String) {
        let m = Model(preview: true)
        m.playing = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: PanelView(m: m).background(Color(nsColor: .windowBackgroundColor)))
            let win = NSWindow(contentRect: .init(x: -4000, y: 0, width: 336, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: appearance)
            win.contentView = host
            let fit = host.fittingSize
            win.setContentSize(fit)
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))   // let the wave ease in
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(dir)/panel-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print(path)
            win.orderOut(nil)
        }
    }

    static func record(to dir: String) {
        let domain = Bundle.main.bundleIdentifier ?? "com.chaitanya.lull"
        let saved = UserDefaults.standard.persistentDomain(forName: domain)   // put the user's settings back after
        let m = Model()
        m.playFor = .min25
        let host = NSHostingView(rootView: PanelView(m: m))
        let win = NSWindow(contentRect: .init(x: -4000, y: 0, width: 336, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setContentSize(host.fittingSize)
        win.orderFrontRegardless()

        // A round already 9 min into its 25, so the bottom row shows the clock.
        func midRound() { let now = Date(); m.phaseStart = now.addingTimeInterval(-540); m.phaseEnd = now.addingTimeInterval(960) }
        func play(_ id: String) {
            guard let x = Mix.find(id) else { return }
            m.category = x.category
            withAnimation(.easeOut(duration: 0.25)) { m.choose(x) }
        }
        let script: [(Double, () -> Void)] = [
            (0.0, { play("lofi"); midRound() }),
            (5.5, { play("rain") }),
            (10.5, { play("sharp") }),
        ]
        let fps = 30.0, seconds = 16.0
        let io = DispatchQueue(label: "record.io", attributes: .concurrent), group = DispatchGroup()
        let start = Date()
        var next = 0, frame = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        while frame < Int(seconds * fps) {
            let t = Date().timeIntervalSince(start)
            while next < script.count && script[next].0 <= t { script[next].1(); next += 1 }
            let due = start.addingTimeInterval(Double(frame) / fps)
            RunLoop.main.run(until: due)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = String(format: "%@/%05d.png", dir, frame)
            group.enter()
            nonisolated(unsafe) let shot = rep   // handed to one writer thread, never touched here again
            io.async { try? shot.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)); group.leave() }
            frame += 1
        }
        m.playing = false
        group.wait()
        if let saved { UserDefaults.standard.setPersistentDomain(saved, forName: domain) }
        print("recorded \(frame) frames to \(dir)")
    }

    static func icon(to dir: String) {
        let view = IconView().frame(width: 1024, height: 1024)
        for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                           (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let r = ImageRenderer(content: view)
            r.scale = CGFloat(px) / 1024
            guard let cg = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
}

private struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [rgb(0x161B24), rgb(0x0B0D12)], startPoint: .top, endPoint: .bottom))
                .padding(100)
            RadialGradient(colors: [rgb(0x46E0A0).opacity(0.35), .clear], center: .init(x: 0.5, y: 0.82), startRadius: 10, endRadius: 420)
                .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous).inset(by: 100))
            HStack(spacing: 34) {
                ForEach(0..<5) { i in
                    let h: [CGFloat] = [190, 330, 470, 330, 190]
                    let c: [UInt32] = [0x39D0F0, 0xFF9548, 0x46E0A0, 0xB48CFF, 0x7C95FF]
                    Capsule().fill(rgb(c[i])).frame(width: 64, height: h[i])
                }
            }
        }
    }
}
