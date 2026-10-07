import Foundation

/// Streaming terminal-control allowlist. ANSI text/color/cursor operations are
/// retained, while OSC (including clipboard/title/cwd/links), DCS/Sixel, APC/kitty
/// graphics and other control strings are discarded without buffering payloads.
/// This deliberately small terminal never needs file transfer or image protocols.
struct OperationTerminalOutputFilter {
    private enum State { case ground, escape, csi, controlString, controlStringEscape }
    private var state = State.ground
    private var sequence: [UInt8] = []
    private var utf8Remaining = 0
    private static let csiFinals = Set("@ABCDEFGH IJKLMPSTXZ`abcdefghlmnpqrsu".utf8)

    mutating func consume(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .ground:
                if utf8Remaining > 0, (0x80...0xbf).contains(byte) {
                    output.append(byte); utf8Remaining -= 1; continue
                }
                utf8Remaining = 0
                if byte == 0x1b { state = .escape }
                else if byte == 0x9b { state = .csi; sequence = [0x1b, 0x5b] }
                else if [0x90, 0x98, 0x9d, 0x9e, 0x9f].contains(byte) { state = .controlString }
                else if byte == 0x9c { continue }
                else if byte >= 0x20 || [8, 9, 10, 13].contains(byte) {
                    output.append(byte)
                    if (0xc2...0xdf).contains(byte) { utf8Remaining = 1 }
                    else if (0xe0...0xef).contains(byte) { utf8Remaining = 2 }
                    else if (0xf0...0xf4).contains(byte) { utf8Remaining = 3 }
                }
            case .escape:
                if byte == 0x5b { state = .csi; sequence = [0x1b, byte] }
                else if [0x5d, 0x50, 0x5f, 0x5e, 0x58].contains(byte) { state = .controlString }
                else {
                    if Array("78DEHM=>c".utf8).contains(byte) { output.append(contentsOf: [0x1b, byte]) }
                    state = byte == 0x1b ? .escape : .ground
                }
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    if Self.csiFinals.contains(byte), sequence.count <= 128, boundedParameters(sequence.dropFirst(2)) {
                        output.append(contentsOf: sequence); output.append(byte)
                    }
                    sequence.removeAll(keepingCapacity: true); state = .ground
                } else if (0x20...0x3f).contains(byte), sequence.count < 129 { sequence.append(byte) }
                else {
                    sequence.removeAll(keepingCapacity: true)
                    state = byte == 0x1b ? .escape : .ground
                }
            case .controlString:
                if byte == 7 || byte == 0x9c { state = .ground }
                else if byte == 0x1b { state = .controlStringEscape }
            case .controlStringEscape:
                if byte == 0x5c || byte == 7 || byte == 0x9c { state = .ground }
                else { state = byte == 0x1b ? .controlStringEscape : .controlString }
            }
        }
        return output
    }

    private func boundedParameters(_ bytes: ArraySlice<UInt8>) -> Bool {
        var value = 0
        for byte in bytes {
            if (48...57).contains(byte) {
                value = value * 10 + Int(byte - 48)
                if value > 4096 { return false }
            } else { value = 0 }
        }
        return true
    }
}
