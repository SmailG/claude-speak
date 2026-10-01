// Calls a handler of a compiled AppleScript with string arguments passed as Apple Event
// parameters. The transcript is never spliced into script source, so a quote or
// `do shell script` inside it is just text.

import Foundation

struct AppleScriptError: Error, CustomStringConvertible {
    let number: Int
    let message: String

    init(info: NSDictionary) {
        number = info[NSAppleScript.errorNumber] as? Int ?? 0
        message = info[NSAppleScript.errorMessage] as? String ?? "unknown"
    }

    var description: String { "AppleScript error \(number): \(message)" }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

/// Not thread-safe (NSAppleScript): use from the main thread only.
final class ScriptHandlers {
    private let script: NSAppleScript

    init(source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(info: [NSAppleScript.errorMessage: "could not create the script"])
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else { throw AppleScriptError(info: error ?? [:]) }
        self.script = script
    }

    @discardableResult
    func call(_ handler: String, _ args: [String] = []) throws -> NSAppleEventDescriptor {
        let params = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() {
            params.insert(NSAppleEventDescriptor(string: arg), at: i + 1)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode("ascr"), eventID: fourCharCode("psbr"),  // subroutine call
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: -1, transactionID: 0)  // kAutoGenerateReturnID, kAnyTransactionID
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: fourCharCode("snam"))
        event.setDescriptor(params, forKeyword: fourCharCode("----"))  // keyDirectObject
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw AppleScriptError(info: error) }
        return result
    }
}
