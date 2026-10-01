// Pure logic of the hotkey helper, unit-tested by tests/helper/GateTests.swift:
// which key triggers, double-tap timing, where a transcript may go, and transcript cleanup.

import Foundation

/// The physical key whose double tap starts voice input (setting file `hotkey`).
enum Hotkey: String, CaseIterable {
    case rightOption = "right-option", rightCommand = "right-command", fn, off

    init(setting: String?) {
        let value = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self = Hotkey(rawValue: value) ?? .rightOption
    }

    /// Virtual keycode (kVK_RightOption, kVK_RightCommand, kVK_Function).
    var keyCode: Int64? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        case .off: return nil
        }
    }

    /// The bit in CGEventFlags that is set while this key is down. The right-hand keys have
    /// device-dependent bits (NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK), so the left key never matches.
    var downBit: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .fn: return 0x80_0000  // maskSecondaryFn
        case .off: return 0
        }
    }

    /// Modifier flags that mean "another modifier is held" (shift, control, option, command, fn),
    /// minus this key's own.
    var otherModifiers: UInt64 {
        let all: UInt64 = 0x2_0000 | 0x4_0000 | 0x8_0000 | 0x10_0000 | 0x80_0000
        switch self {
        case .rightOption: return all & ~0x8_0000
        case .rightCommand: return all & ~0x10_0000
        case .fn: return all & ~0x80_0000
        case .off: return all
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .fn: return "Fn"
        case .off: return "off"
        }
    }
}

enum TapEvent: Equatable { case none, tap, doubleTap }

/// Two quick presses of the key alone. Each press is shorter than `maxPress`, the second starts
/// within `maxGap` of the first ending, and nothing else is pressed in between, so holding the
/// key for a shortcut (Right Option + 2 = @ on many layouts) never counts.
struct DoubleTapDetector {
    static let maxPress = 0.2
    static let maxGap = 0.35

    private var downAt: Double?
    private var tapEndedAt: Double?

    mutating func keyDown(at t: Double, othersHeld: Bool) {
        if othersHeld { return interrupted() }
        if let end = tapEndedAt, t - end > Self.maxGap { tapEndedAt = nil }
        downAt = t
    }

    mutating func keyUp(at t: Double) -> TapEvent {
        guard let down = downAt else { return .none }
        downAt = nil
        guard t - down < Self.maxPress else {
            tapEndedAt = nil
            return .none
        }
        if tapEndedAt != nil {
            tapEndedAt = nil
            return .doubleTap
        }
        tapEndedAt = t
        return .tap
    }

    /// Any other key or modifier: whatever was in progress is not a tap.
    mutating func interrupted() {
        downAt = nil
        tapEndedAt = nil
    }
}

enum TerminalApp: String {
    case iTerm2 = "com.googlecode.iterm2", terminal = "com.apple.Terminal"
}

/// "/dev/ttys009" -> "ttys009"; nil for anything that isn't a terminal name.
func ttyName(_ path: String) -> String? {
    let name = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
    return name.range(of: "^tty[a-z]*[0-9]+$", options: .regularExpression) != nil ? name : nil
}

enum Delivery: Equatable { case type, clipboard }

/// Where a finished transcript goes. Never typed into a session showing a menu (a permission
/// prompt or a question), where "yes" or "2" would answer it. Terminal.app can only paste into
/// its front tab, so if the user switched tabs the text goes to the clipboard instead.
func delivery(app: TerminalApp, tty: String, guarded: [String], frontTTYNow: String?) -> Delivery {
    if guarded.contains(tty) { return .clipboard }
    if app == .terminal && frontTTYNow != tty { return .clipboard }
    return .type
}

/// Make a transcript safe to type into Claude Code: control characters (newlines that would
/// submit, escape sequences) become spaces, and a leading "/", "!", "#" or "?" (a command, shell
/// mode, memory, help) is dropped.
func sanitizeTranscript(_ text: String) -> String {
    let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
    var clean = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    while let first = clean.first, "/!#?".contains(first) {
        clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return clean
}
