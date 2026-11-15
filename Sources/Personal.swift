// Personal mixes: none in the public build. `build.sh` compiles personal/Personal.swift instead of this
// file when that folder exists (it is gitignored), so a local build can add mixes from your own audio.

extension Mix {
    static let personal: [Mix] = []
}

let personalLines: [String: [(Double, Double)]] = [:]
