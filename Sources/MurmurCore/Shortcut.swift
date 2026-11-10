import Foundation

/// A global keyboard shortcut: a virtual key code and Carbon modifier flags.
public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon's modifier bits (Events.h).
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// ⌃X: dictate and polish.
    public static let `default` = Shortcut(keyCode: 0x07, modifiers: control)
    /// ⌃⌘X: dictate, polish and translate.
    public static let translateDefault = Shortcut(keyCode: 0x07, modifiers: control | command)

    public var hasModifier: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// The modifier symbols, in the order macOS writes them.
    public var modifierSymbols: [String] {
        var out: [String] = []
        if modifiers & Self.control != 0 { out.append("⌃") }
        if modifiers & Self.option != 0 { out.append("⌥") }
        if modifiers & Self.shift != 0 { out.append("⇧") }
        if modifiers & Self.command != 0 { out.append("⌘") }
        return out
    }

    public var keyName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// Each key cap, for drawing: ["⌃", "X"].
    public var caps: [String] { modifierSymbols + [keyName] }

    public var display: String { caps.joined() }

    /// Whether a shortcut made of this key would be usable: a function key
    /// alone, or anything with ⌘, ⌥ or ⌃.
    public var isValid: Bool { hasModifier || Self.functionKeys.contains(keyCode) }

    static let functionKeys: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                            0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

    static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
        0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".",
        0x2C: "/", 0x32: "`",
        0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]
}
