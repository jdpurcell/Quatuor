import Foundation
import AVFoundation

/// Encodes PCM audio to MP3 using libmp3lame (VBR V2, ~190 kbps).
///
/// Requires `libmp3lame.a` to be compiled and linked. See `Scripts/build_lame.sh`
/// and the bridging header at `Quatuor/AudioIO/lame-bridge.h`.
@MainActor
final class MP3Encoder {
    static let shared = MP3Encoder()

    enum Error: LocalizedError {
        case userCancelled
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .userCancelled:    String(localized: "Export annulé")
            case .writeFailed(let m): String(localized: "Écriture MP3 échouée : \(m)")
            }
        }
    }

    /// Internal rather than private so the test suite can encode without a save panel.
    nonisolated func encode(pcmFileURL: URL, to destination: URL) async throws {
        let sourceFile = try AVAudioFile(forReading: pcmFileURL)
        let format = sourceFile.processingFormat
        let sampleRate = Int32(format.sampleRate)
        let channels = format.channelCount

        guard let lame = lame_init() else {
            throw Error.writeFailed("lame_init() a retourné nil")
        }
        defer { lame_close(lame) }

        lame_set_in_samplerate(lame, sampleRate)
        lame_set_num_channels(lame, Int32(channels))
        lame_set_VBR(lame, vbr_default)
        lame_set_VBR_quality(lame, 2)

        guard lame_init_params(lame) >= 0 else {
            throw Error.writeFailed("lame_init_params() a échoué")
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw Error.writeFailed(destination.lastPathComponent)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw Error.writeFailed("Impossible de créer le buffer PCM")
        }

        let mp3BufSize = Int(1.25 * Double(chunkFrames) + 7200)
        var mp3Buf = [UInt8](repeating: 0, count: mp3BufSize)

        while sourceFile.framePosition < sourceFile.length {
            try sourceFile.read(into: buffer)
            let frames = Int32(buffer.frameLength)
            guard frames > 0 else { break }

            let left = buffer.floatChannelData![0]
            let right = channels > 1 ? buffer.floatChannelData![1] : left

            let written = lame_encode_buffer_ieee_float(
                lame,
                left,
                right,
                frames,
                &mp3Buf,
                Int32(mp3BufSize)
            )

            if written < 0 {
                throw Error.writeFailed("lame_encode a retourné \(written)")
            }
            if written > 0 {
                handle.write(Data(bytes: mp3Buf, count: Int(written)))
            }
        }

        let flushed = lame_encode_flush(lame, &mp3Buf, Int32(mp3BufSize))
        guard flushed >= 0 else {
            throw Error.writeFailed("lame_encode_flush: \(flushed)")
        }
        if flushed > 0 {
            handle.write(Data(bytes: mp3Buf, count: Int(flushed)))
        }
    }
}
