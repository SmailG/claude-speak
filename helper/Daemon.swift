// HTTP client for the local speech service (speakd). Blocking calls with short timeouts:
// the service is on localhost, and only /transcribe takes long (call that off the main thread).

import Foundation

struct Health {
    let sessions: [String]  // ttys of open Claude Code sessions
    let guarded: [String]   // ttys showing a permission prompt or question
    let voiceInput: Bool
}

final class Daemon: @unchecked Sendable {
    static let transcribeTimeout = 130.0

    private let base: URL

    init(port: Int) {
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    func health() -> Health? {
        guard let (code, data) = request("health"), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Health(sessions: json["sessions"] as? [String] ?? [],
                      guarded: json["guarded"] as? [String] ?? [],
                      voiceInput: json["voice_input"] as? Bool ?? false)
    }

    /// Silences speech (empty body = every session) and starts loading Whisper.
    func prepare() {
        _ = request("stop", body: Data())
        _ = request("prepare", body: Data())
    }

    func transcribe(_ wav: Data) -> Result<String, TranscribeError> {
        guard let (code, data) = request("transcribe", body: wav, timeout: Self.transcribeTimeout) else {
            return .failure(TranscribeError(message: "the speech service did not answer"))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200, let text = json?["text"] as? String else {
            return .failure(TranscribeError(message: json?["error"] as? String ?? "HTTP \(code)"))
        }
        return .success(text)
    }

    private func request(_ path: String, body: Data? = nil, timeout: Double = 1) -> (Int, Data)? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse { box.value = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }
}

struct TranscribeError: Error {
    let message: String
}

private final class ResponseBox: @unchecked Sendable {
    var value: (Int, Data)?
}
