import AVFoundation
import Foundation
import Testing

@testable import Quatuor

// MARK: - Fixtures

/// Writes `seconds` of a 440 Hz sine to a temporary WAV file and returns its URL.
private func makeSineWAV(
    seconds: Double = 1.0,
    sampleRate: Double = 44_100,
    channels: AVAudioChannelCount = 2,
    amplitude: Float = 0.5
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quatuor-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)

    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(frames) {
            samples[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
    }
    try file.write(from: buffer)
    return url
}

// MARK: - Stem kinds

@MainActor
@Suite("Stem kinds")
struct StemKindTests {

    /// htdemucs returns its keys in whatever case it pleases; the mapping absorbs that.
    @Test func matchesModelKeysWhateverTheirCase() {
        #expect(StemKind(fromModelKey: "vocals") == .vocals)
        #expect(StemKind(fromModelKey: "Drums") == .drums)
        #expect(StemKind(fromModelKey: "BASS") == .bass)
        #expect(StemKind(fromModelKey: "Other") == .other)
    }

    @Test func rejectsAKeyThatIsNotAStem() {
        #expect(StemKind(fromModelKey: "piano") == nil)
        #expect(StemKind(fromModelKey: "") == nil)
    }

    @Test func coversTheFourStemsInAStableOrder() {
        #expect(StemKind.allCases == [.vocals, .drums, .bass, .other])
    }
}

// MARK: - Decoding

@MainActor
@Suite("Audio decoding")
struct AudioDecoderTests {

    @Test func readsMetadataFromTheFile() async throws {
        let url = try makeSineWAV(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try await AudioDecoder.preview(url: url)

        #expect(source.sampleRate == 44_100)
        #expect(source.channelCount == 2)
        #expect(abs(source.durationSeconds - 1.0) < 0.01)
        #expect(source.displayName == url.lastPathComponent)
    }

    /// The waveform view draws peaks directly, so they must land in [0, 1] with
    /// the loudest one at exactly 1 — otherwise a quiet file renders as a flat line.
    @Test func normalisesThePeaksItComputes() async throws {
        let url = try makeSineWAV(seconds: 1.0, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = try await AudioDecoder.preview(url: url).waveformPeaks

        #expect(!peaks.isEmpty)
        #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(abs((peaks.max() ?? 0) - 1) < 0.0001)
    }

    /// ~2 000 peaks whatever the duration: the view samples a fixed width.
    @Test func producesAStableNumberOfPeaks() async throws {
        let short = try makeSineWAV(seconds: 0.5)
        let long = try makeSineWAV(seconds: 4.0)
        defer {
            try? FileManager.default.removeItem(at: short)
            try? FileManager.default.removeItem(at: long)
        }

        let shortPeaks = try await AudioDecoder.preview(url: short).waveformPeaks.count
        let longPeaks = try await AudioDecoder.preview(url: long).waveformPeaks.count

        #expect((1_900...2_100).contains(shortPeaks))
        #expect((1_900...2_100).contains(longPeaks))
    }

    @Test func refusesAFileThatIsNotAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quatuor-test-\(UUID().uuidString).wav")
        try Data("this is not a WAV".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await AudioDecoder.preview(url: url)
        }
    }
}

// MARK: - MP3 export

@MainActor
@Suite("MP3 encoding")
struct MP3EncoderTests {

    @Test func writesAnMP3ThatPlaysBack() async throws {
        let wav = try makeSineWAV(seconds: 0.5)
        let mp3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("quatuor-test-\(UUID().uuidString).mp3")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: mp3)
        }

        try await MP3Encoder.shared.encode(pcmFileURL: wav, to: mp3)

        let size = try FileManager.default.attributesOfItem(atPath: mp3.path)[.size] as? Int ?? 0
        #expect(size > 0)

        // Reading it back is the real check: libmp3lame was configured and flushed.
        let encoded = try AVAudioFile(forReading: mp3)
        let duration = Double(encoded.length) / encoded.processingFormat.sampleRate
        #expect(abs(duration - 0.5) < 0.1)
    }
}

// MARK: - Result lifecycle

@MainActor
@Suite("Result lifecycle")
struct SeparationResultTests {

    /// Each separation leaves four WAVs in a temporary directory. Leaving the
    /// `.done` phase must delete them, or a long session fills the disk.
    @Test func leavingTheDonePhaseDeletesTheTemporaryFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quatuor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let stemFile = tempDir.appendingPathComponent("vocals.wav")
        try Data("pcm".utf8).write(to: stemFile)

        let source = LoadedSource(
            url: tempDir.appendingPathComponent("source.mp3"),
            displayName: "source.mp3",
            durationSeconds: 1,
            sampleRate: 44_100,
            channelCount: 2,
            waveformPeaks: [0, 1]
        )
        let result = SeparationResult(
            source: source,
            stems: [.init(kind: .vocals, pcmFileURL: stemFile, waveformPeaks: [0, 1])],
            tempDirectory: tempDir
        )

        let state = AppState()
        state.phase = .done(result)
        #expect(FileManager.default.fileExists(atPath: tempDir.path))

        state.reset()
        #expect(!FileManager.default.fileExists(atPath: tempDir.path))
    }
}

// MARK: - Lossless export and mix rendering

@MainActor
@Suite("Audio export")
struct AudioExporterTests {
    private func readSamples(_ url: URL) throws -> (AVAudioFormat, [[Float]]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file.fileFormat, (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        })
    }

    @Test(arguments: [ExportFormat.wav, .flac])
    func losslessExportPreservesSamplesAndFormat(_ format: ExportFormat) async throws {
        let source = try makeSineWAV(seconds: 0.5, amplitude: 0.25)
        let destination = source.deletingPathExtension().appendingPathExtension(format.rawValue)
        // WAV needs a distinct output path.
        let output = destination.deletingLastPathComponent()
            .appendingPathComponent("export-\(UUID().uuidString).\(format.rawValue)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try await AudioExporter.encode(pcmFileURL: source, to: output, format: format)
        let (_, expected) = try readSamples(source)
        let (fileFormat, actual) = try readSamples(output)
        #expect(fileFormat.streamDescription.pointee.mFormatID ==
                (format == .flac ? kAudioFormatFLAC : kAudioFormatLinearPCM))
        if format == .flac {
            #expect(fileFormat.streamDescription.pointee.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData)
        } else {
            #expect(fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        }
        #expect(fileFormat.sampleRate == 44_100)
        #expect(actual.count == 2)
        #expect(actual[0].count == expected[0].count)
        for channel in 0..<2 {
            let error = zip(expected[channel], actual[channel]).map { abs($0 - $1) }.max()!
            #expect(error <= 1 / Float(32768))
        }
    }

    @Test func mixHonorsGainsAndSilenceAcrossChunks() throws {
        let source = try makeSineWAV(seconds: 0.5, amplitude: 0.4)
        let mix = source.deletingLastPathComponent().appendingPathComponent("mix-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: mix)
        }
        try AudioExporter.renderMix(inputs: [
            .init(url: source, gain: 0.25), .init(url: source, gain: 0.5), .init(url: source, gain: 0)
        ], to: mix)
        let (_, original) = try readSamples(source)
        let (_, rendered) = try readSamples(mix)
        #expect(rendered[0].count == original[0].count)
        for channel in 0..<2 {
            let error = zip(original[channel], rendered[channel]).map { abs($0 * 0.75 - $1) }.max()!
            #expect(error < 0.000001)
        }
        try AudioExporter.renderMix(inputs: [.init(url: source, gain: 0)], to: mix)
        let (_, silent) = try readSamples(mix)
        #expect(silent.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func mixAttenuatesTheWholeSongOnlyWhenItWouldClip() throws {
        let source = try makeSineWAV(seconds: 0.5, amplitude: 0.8)
        let mix = source.deletingLastPathComponent().appendingPathComponent("mix-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: mix)
        }
        try AudioExporter.renderMix(inputs: [.init(url: source, gain: 1), .init(url: source, gain: 1)], to: mix)
        let (_, original) = try readSamples(source)
        let (_, rendered) = try readSamples(mix)
        let originalPeak = original[0].map { abs($0) }.max()!
        let peak = rendered[0].map { abs($0) }.max()!
        #expect(abs(peak - 1) < 0.000001)
        let error = zip(original[0], rendered[0]).map { abs($0 / originalPeak - $1) }.max()!
        #expect(error < 0.000001)
    }

    @Test func mixerGainRespectsMuteAndSolo() {
        #expect(StemPlayer.effectiveVolume(track: .init(volume: 0.3), hasSolo: false) == 0.3)
        #expect(StemPlayer.effectiveVolume(track: .init(isMuted: true, isSoloed: true), hasSolo: true) == 0)
        #expect(StemPlayer.effectiveVolume(track: .init(volume: 0.3), hasSolo: true) == 0)
        #expect(StemPlayer.effectiveVolume(track: .init(isSoloed: true, volume: 0.7), hasSolo: true) == 0.7)
    }
}

@Suite("Model download progress")
struct ModelDownloadProgressTests {
    @Test func unknownContentLengthStillReportsReceivedBytes() {
        let updates = ProgressUpdates()
        let delegate = DownloadDelegate(fileIndex: 1, fileCount: 2) { updates.append($0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        delegate.urlSession(session, downloadTask: task, didWriteData: 4096,
                            totalBytesWritten: 8192, totalBytesExpectedToWrite: NSURLSessionTransferSizeUnknown)
        let progress = updates.values.first
        #expect(progress?.bytesReceived == 8192)
        #expect(progress?.fileIndex == 1)
        #expect(progress?.fraction == nil)
    }

    @Test func knownContentLengthReportsPercentage() {
        let updates = ProgressUpdates()
        let delegate = DownloadDelegate(fileIndex: 2, fileCount: 2) { updates.append($0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        delegate.urlSession(session, downloadTask: task, didWriteData: 25,
                            totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        #expect(updates.values.first?.fraction == 0.5)
        #expect(updates.values.first?.fileIndex == 2)
    }
}

private nonisolated final class ProgressUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ModelDownloadProgress] = []
    func append(_ progress: ModelDownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(progress)
    }
    var values: [ModelDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

// MARK: - Playback seeking

@MainActor
@Suite("Playback seeking", .serialized)
struct StemPlayerSeekTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                   "Realtime playback requires a local audio output device."))
    func seekingWhilePlayingContinuesFromTheNewPosition() async throws {
        // Silent fixtures exercise the actual engine without playing test tones.
        let url = try makeSineWAV(seconds: 12, amplitude: 0)
        let player = StemPlayer()
        defer {
            player.unload()
            try? FileManager.default.removeItem(at: url)
        }
        let stems = StemKind.allCases.map {
            SeparationResult.Stem(kind: $0, pcmFileURL: url, waveformPeaks: [])
        }
        player.load(stems: stems)
        player.togglePlayPause()
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.isPlaying)
        #expect(player.progress > 0)

        for fraction in [0.5, 0.2, 0.75] {
            player.seek(fraction: fraction)
            try await Task.sleep(for: .milliseconds(250))
            let elapsed = player.progress * player.duration - fraction * player.duration
            #expect(player.isPlaying)
            #expect(elapsed > 0.05)
            #expect(elapsed < 0.6)
        }

        // A drag sends many seeks, and playback must continue after the last one.
        for step in 20...40 {
            player.seek(fraction: Double(step) / 100)
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.isPlaying)
        #expect(player.progress > 0.4)
        #expect(player.progress < 0.45)

        player.togglePlayPause()
        player.seek(fraction: 0.6)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!player.isPlaying)
        #expect(player.progress == 0.6)
        player.togglePlayPause()
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.isPlaying)
        #expect(player.progress > 0.6)
        #expect(player.progress < 0.65)
    }
}
