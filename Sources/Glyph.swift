import SwiftUI

/// Spectral peaks of each loop (Hz, relative level), measured from audio/loops/*.caf by FFT.
/// The panel draws these in previews and snapshots, where no audio is playing.
let loopLines: [String: [(Double, Double)]] = [
    "sharp": [(133.8, 0.99), (173.8, 1.0)],
    "lofi": [(43.9, 0.6), (130.4, 0.62), (196.3, 0.6), (262.2, 1), (329.6, 0.91), (392.6, 0.61)],
].merging(personalLines) { a, _ in a }

/// x in 0...1 for a frequency on a log axis 40...600 Hz.
func logX(_ hz: Double) -> Double { (log(hz) - log(40)) / (log(600) - log(40)) }

// MARK: - 5×7 dot font (hand-set; the display voice of the panel)

enum DotFont {
    static let g: [Character: [String]] = [
        "A": [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
        "B": ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
        "C": [" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "],
        "D": ["#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "],
        "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
        "F": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
        "G": [" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ####"],
        "H": ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
        "I": ["###", " # ", " # ", " # ", " # ", " # ", "###"],
        "K": ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
        "L": ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
        "M": ["#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"],
        "N": ["#   #", "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #"],
        "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
        "P": ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
        "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
        "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
        "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
        "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
        "V": ["#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "],
        "W": ["#   #", "#   #", "#   #", "# # #", "# # #", "# # #", " # # "],
        "X": ["#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"],
        "Y": ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
        "Z": ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
        "0": [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
        "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
        "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
        "3": ["#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "],
        "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
        "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
        "6": ["  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "],
        "7": ["#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "],
        "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
        "9": [" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "],
        ":": [" ", "#", " ", " ", " ", "#", " "],
        "/": ["    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "],
        "-": ["   ", "   ", "   ", "###", "   ", "   ", "   "],
        " ": ["  ", "  ", "  ", "  ", "  ", "  ", "  "],
    ]

    static func cells(_ s: String) -> (w: Int, on: [(Int, Int)]) {
        var x = 0
        var on: [(Int, Int)] = []
        for ch in s.uppercased() {
            let rows = g[ch] ?? g[" "]!
            for (y, row) in rows.enumerated() {
                for (i, c) in row.enumerated() where c == "#" { on.append((x + i, y)) }
            }
            x += rows[0].count + 1
        }
        return (max(0, x - 1), on)
    }
}

/// Text set in the dot font: round dots (dot-matrix display) or square pixels.
struct DotText: View {
    let text: String
    let cell: CGFloat
    var color: Color
    var off: Color? = nil
    var round = true
    var fill: CGFloat = 0.8

    var body: some View {
        let c = DotFont.cells(text)
        Canvas { ctx, _ in
            func dot(_ x: Int, _ y: Int, _ col: Color) {
                let s = cell * fill, o = (cell - s) / 2
                let r = CGRect(x: CGFloat(x) * cell + o, y: CGFloat(y) * cell + o, width: s, height: s)
                ctx.fill(round ? Path(ellipseIn: r) : Path(r), with: .color(col))
            }
            if let off { for x in 0..<c.w { for y in 0..<7 { dot(x, y, off) } } }
            for (x, y) in c.on { dot(x, y, color) }
        }
        .frame(width: CGFloat(c.w) * cell, height: 7 * cell)
    }

    /// Cell size that sets `text` exactly `width` wide.
    static func fit(_ text: String, _ width: CGFloat) -> CGFloat { width / CGFloat(DotFont.cells(text).w) }
}

