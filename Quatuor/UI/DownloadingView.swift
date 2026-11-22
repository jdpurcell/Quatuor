import SwiftUI

struct DownloadingView: View {
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeat(.continuous))

            Text("Téléchargement du modèle…")
                .font(.title3.weight(.medium))

            Text("htdemucs_ft · ~670 Mo · première utilisation uniquement")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Fichier \(progress.fileIndex) sur \(progress.fileCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)

            if let fraction = progress.fraction {
                Text("\(Int(fraction * 100)) %")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(progress.bytesReceived.formatted(.byteCount(style: .file)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }
}
