// The macOS privacy permissions the helper needs, and a status file that /speak status reads.
//   Input Monitoring  see the double tap (a listen-only event tap; keys are never consumed or logged)
//   Microphone        record what you say
//   Automation        ask iTerm2 / Terminal which tab is in front and type into it
//   Accessibility     Terminal.app only: paste with Cmd+V and press Return

import AVFoundation
import AppKit
import CoreServices

enum Permissions {
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var microphone: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "not asked"
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in log("microphone \(granted ? "granted" : "denied")") }
    }

    static func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Asks for Automation of each running supported terminal now, while setup has the user's
    /// attention, instead of at the first double tap. Blocks while a prompt is open, so off main.
    static func primeAutomation() {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let wildcard: FourCharCode = 0x2A2A_2A2A  // typeWildCard '****'
        DispatchQueue.global(qos: .utility).async {
            for app in [TerminalApp.iTerm2, .terminal] where running.contains(app.rawValue) {
                let target = NSAppleEventDescriptor(bundleIdentifier: app.rawValue)
                guard let desc = target.aeDesc else { continue }
                let status = AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, true)
                log("automation of \(app): \(status == noErr ? "granted" : "status \(status)")")
            }
        }
    }

    static func writeStatus(dataDir: String, hotkey: Hotkey) {
        let status: [String: Any] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "hotkey": hotkey.rawValue,
            "input_monitoring": inputMonitoring,
            "microphone": microphone,
            "accessibility": accessibility,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: dataDir).appendingPathComponent("hotkey_status.json"),
                        options: .atomic)
    }
}
