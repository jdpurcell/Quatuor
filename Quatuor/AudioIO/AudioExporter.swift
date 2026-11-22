import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// One format choice for individual stems, all stems, and the current mix.
nonisolated enum ExportFormat: String, CaseIterable, Sendable {
    case mp3, wav, flac

    var label: String { rawValue.uppercased() }
    var contentType: UTType { UTType(filenameExtension: rawValue)! }
}

@MainActor
final class AudioExporter {
    static let shared = AudioExporter()

    enum Error: LocalizedError {
        case userCancelled
        case incompatibleAudio
        var errorDescription: String? {
            switch self {
            case .userCancelled: String(localized: "Export annulé")
            case .incompatibleAudio: String(localized: "Les pistes audio ne sont pas compatibles pour le mixage.")
            }
        }
    }

    nonisolated struct MixInput: Sendable {
        let url: URL
        let gain: Float
    }

    func export(pcmFileURL: URL, suggestedName: String, format: ExportFormat) async throws {
        let destination = try await pickDestination(name: suggestedName, format: format)
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try await Task.detached(priority: .userInitiated) {
            try await Self.encode(pcmFileURL: pcmFileURL, to: destination, format: format)
        }.value
    }

    func exportAll(stems: [SeparationResult.Stem], baseName: String, format: ExportFormat) async throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exporter ici")
        guard await panel.begin() == .OK, let folder = panel.url else { throw Error.userCancelled }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = stems.map { stem in
            (stem.pcmFileURL, folder.appendingPathComponent("\(baseName) - \(stem.kind.label).\(format.rawValue)"))
        }
        if files.contains(where: { FileManager.default.fileExists(atPath: $0.1.path) }) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Remplacer les fichiers existants ?")
            alert.informativeText = String(localized: "Les stems portant le même nom dans ce dossier seront remplacés.")
            alert.addButton(withTitle: String(localized: "Remplacer"))
            alert.addButton(withTitle: String(localized: "Annuler"))
            guard alert.runModal() == .alertFirstButtonReturn else { throw Error.userCancelled }
        }
        try await Task.detached(priority: .userInitiated) {
            for (source, destination) in files {
                try await Self.encode(pcmFileURL: source, to: destination, format: format)
            }
        }.value
    }

    func exportMix(inputs: [MixInput], suggestedName: String, format: ExportFormat) async throws {
        let destination = try await pickDestination(name: suggestedName, format: format)
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("Quatuor-mix-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.renderMix(inputs: inputs, to: temporary)
            try await Self.encode(pcmFileURL: temporary, to: destination, format: format)
        }.value
    }

    private func pickDestination(name: String, format: ExportFormat) async throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(name).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { throw Error.userCancelled }
        return url
    }

    /// WAV and FLAC preserve the 16-bit precision of the generated stems.
    nonisolated static func encode(pcmFileURL: URL, to destination: URL, format: ExportFormat) async throws {
        if format == .mp3 {
            try await MP3Encoder.shared.encode(pcmFileURL: pcmFileURL, to: destination)
            return
        }
        let source = try AVAudioFile(forReading: pcmFileURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let pcm = source.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: format == .flac ? kAudioFormatFLAC : kAudioFormatLinearPCM,
            AVSampleRateKey: pcm.sampleRate,
            AVNumberOfChannelsKey: pcm.channelCount
        ]
        if format == .flac {
            settings[AVEncoderBitDepthHintKey] = 16
        } else {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        }
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
            throw Error.incompatibleAudio
        }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// Stream aligned stems in bounded chunks, then attenuate only if the sum clips.
    /// A single gain for the whole song preserves the chosen balance and dynamics.
    nonisolated static func renderMix(inputs: [MixInput], to destination: URL) throws {
        let files = try inputs.map { try AVAudioFile(forReading: $0.url) }
        guard let first = files.first,
              let pcm = AVAudioFormat(standardFormatWithSampleRate: first.processingFormat.sampleRate,
                                      channels: first.processingFormat.channelCount),
              files.allSatisfy({ $0.processingFormat.sampleRate == pcm.sampleRate &&
                  $0.processingFormat.channelCount == pcm.channelCount && $0.length == first.length }),
              inputs.allSatisfy({ $0.gain.isFinite && $0.gain >= 0 && $0.gain <= 1 }),
              let sum = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
            throw Error.incompatibleAudio
        }
        let buffers = try files.map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
                throw Error.incompatibleAudio
            }
            return buffer
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Quatuor-sum-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var peak: Float = 0
        // Close the writer before opening the scratch file for the second pass.
        do {
            let output = try AVAudioFile(forWriting: scratch, settings: pcm.settings)
            while first.framePosition < first.length {
                let count = AVAudioFrameCount(min(8192, first.length - first.framePosition))
                sum.frameLength = count
                for channel in 0..<Int(pcm.channelCount) {
                    sum.floatChannelData![channel].initialize(repeating: 0, count: Int(count))
                }
                for (index, file) in files.enumerated() {
                    try file.read(into: buffers[index], frameCount: count)
                    guard buffers[index].frameLength == count else { throw Error.incompatibleAudio }
                    let gain = inputs[index].gain
                    for channel in 0..<Int(pcm.channelCount) {
                        for frame in 0..<Int(count) {
                            sum.floatChannelData![channel][frame] += buffers[index].floatChannelData![channel][frame] * gain
                        }
                    }
                }
                for channel in 0..<Int(pcm.channelCount) {
                    for frame in 0..<Int(count) {
                        peak = max(peak, abs(sum.floatChannelData![channel][frame]))
                    }
                }
                try output.write(from: sum)
            }
        }
        let source = try AVAudioFile(forReading: scratch)
        let output = try AVAudioFile(forWriting: destination, settings: pcm.settings)
        let gain: Float = peak > 1 ? 1 / peak : 1
        while source.framePosition < source.length {
            try source.read(into: sum)
            guard sum.frameLength > 0 else { break }
            for channel in 0..<Int(pcm.channelCount) {
                for frame in 0..<Int(sum.frameLength) {
                    sum.floatChannelData![channel][frame] *= gain
                }
            }
            try output.write(from: sum)
        }
    }
}
