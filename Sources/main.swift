import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if args.contains("--selftest") { SelfTest.run() }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        _ = NSApplication.shared
        Render.snapshot(to: args[i + 1]); exit(0)
    }
    if let i = args.firstIndex(of: "--record"), i + 1 < args.count {
        _ = NSApplication.shared
        Render.record(to: args[i + 1]); exit(0)
    }
    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
        Render.icon(to: args[i + 1]); exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
