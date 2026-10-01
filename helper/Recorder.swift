// Records the microphone until stopped, after a long silence, or at the time cap.

import AVFoundation

final class Recorder {
    static let silenceLimit = 15.0  // seconds without speech before it stops by itself
    static let maxDuration = 120.0
    static let speechLevel: Float = 0.01  // RMS above which a buffer counts as speech

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var startedAt = Date()
    private var lastSpeechAt = Date()
    private var autoStopSent = false
    private(set) var sampleRate = 48000

    /// Called once on the main queue when silence or the time cap ends the recording.
    var onAutoStop: (() -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = Int(format.sampleRate)
        samples = []
        startedAt = Date()
        lastSpeechAt = startedAt
        autoStopSent = false
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops and returns the recording as a 16-bit mono WAV at the device's sample rate.
    func stop() -> (wav: Data, seconds: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let recorded = samples
        samples = []
        lock.unlock()
        return (wavData(samples: recorded, sampleRate: sampleRate), Double(recorded.count) / Double(sampleRate))
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1))).squareRoot()
        lock.lock()
        samples += chunk
        lock.unlock()
        let now = Date()
        if rms > Self.speechLevel { lastSpeechAt = now }
        let silent = now.timeIntervalSince(lastSpeechAt) > Self.silenceLimit
        let tooLong = now.timeIntervalSince(startedAt) > Self.maxDuration
        if (silent || tooLong) && !autoStopSent {
            autoStopSent = true
            DispatchQueue.main.async { [weak self] in self?.onAutoStop?() }
        }
    }
}
