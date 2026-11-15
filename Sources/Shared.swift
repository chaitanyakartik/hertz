import Foundation
import SwiftUI

// Compiled into both the app and the widget extension.

enum Mode: String, CaseIterable, Identifiable {
    case focus, flow, calm, drift, sleep
    var id: String { rawValue }

    var title: String { rawValue.capitalized }
    var beat: Double { [40, 16, 10, 6, 2][index] }
    var carrier: Double { [300, 250, 200, 180, 150][index] }
    var band: String { ["gamma", "beta", "alpha", "theta", "delta"][index] }
    var feel: String { ["sharp attention", "steady work", "relaxed alertness", "daydream, unwind", "deep rest"][index] }
    var symbol: String { ["scope", "wind", "leaf", "cloud", "moon.stars"][index] }
    var beatLabel: String { "\(Int(beat)) Hz" }
    /// How the generative music behaves in this mode.
    var tempo: Double { [100, 92, 76, 66, 56][index] }
    var density: Double { [0.9, 0.8, 0.6, 0.45, 0.3][index] }
    var bright: Double { [1.3, 1.15, 1.0, 0.8, 0.6][index] }
    var dark: Bool { index >= 3 }
    private var index: Int { Mode.allCases.firstIndex(of: self)! }

    /// Bright trace colour for the dark scope and dark-mode accents.
    var glow: Color { [rgb(0x39D0F0), rgb(0xFF9548), rgb(0x46E0A0), rgb(0xB48CFF), rgb(0x7C95FF)][index] }
    /// Deeper version that holds contrast on light backgrounds.
    var ink: Color { [rgb(0x0A86A6), rgb(0xC25A10), rgb(0x128A5A), rgb(0x7A4CE0), rgb(0x3F5BE0)][index] }
    func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? glow : ink }
}

func rgb(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// What the widget shows. The app writes it; the sandboxed widget reads it through a
/// read-only file exception (see Widget/HertzWidget.entitlements).
struct SharedState: Codable {
    var mode: String
    var playing: Bool
    var timerEnd: Date?

    static var url: URL {
        // Real home, even inside the widget's sandbox container.
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Hertz/state.json")
    }

    static func load() -> SharedState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedState.self, from: d)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}
