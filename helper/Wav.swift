// 16-bit PCM WAV encoding for the recording sent to the daemon's POST /transcribe.

import Foundation

func wavData(samples: [Float], sampleRate: Int) -> Data {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let payload = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + payload))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); put(UInt32(payload))
    for s in samples {
        put(Int16(max(-1, min(1, s)) * 32767))
    }
    return data
}
