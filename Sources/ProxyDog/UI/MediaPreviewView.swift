import AVKit
import SwiftUI

/// Inline video/audio preview for captured media bodies, mirroring the image preview.
///
/// AVFoundation needs a file URL, so the captured bytes are written to a temporary file
/// once the view appears (and removed when it goes away). Bodies truncated by the 2 MB
/// capture cap still get a player: many MP4s put `moov` up front and play partially.
struct MediaBodyView: View {
    let data: Data
    let contentType: String?
    let isVideo: Bool

    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var isUnplayable = false

    /// Media captured right at the hard capture limit may be incomplete.
    private var wasTruncated: Bool {
        data.count >= AppDefaults.maxBodyBytes
    }

    private var formatLabel: String {
        contentType ?? (isVideo ? "video" : "audio")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                PlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DSColor.sunken)
                caption(for: player)
            } else if isUnplayable {
                VStack(spacing: 0) {
                    noticeRow(String(localized: "This media format cannot be previewed; showing raw bytes"))
                    HexDumpView(data: data)
                }
            } else {
                ZStack {
                    DSColor.sunken
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: data.count) {
            prepare()
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            tempURL = nil
        }
    }

    private func caption(for player: AVPlayer) -> some View {
        HStack(spacing: DS.Space.x2) {
            Text(formatLabel)
            Text(PDFormat.bytes(data.count))
                .monospacedDigit()
            if wasTruncated {
                Text(String(localized: "Captured up to the 2 MB limit; playback may be incomplete"))
            }
            Spacer(minLength: 0)
        }
        .font(DS.Typography.mono(10.5))
        .foregroundStyle(DSColor.textMuted)
        .padding(.horizontal, DS.Space.x3)
        .frame(height: 22)
        .background(DSColor.raised)
        .overlay(alignment: .top) { PDHairline() }
    }

    private func prepare() {
        guard player == nil, !isUnplayable else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyDogMedia", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + "." + fileExtension)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            isUnplayable = true
            return
        }
        tempURL = url

        let asset = AVURLAsset(url: url)
        guard asset.isPlayable else {
            isUnplayable = true
            try? FileManager.default.removeItem(at: url)
            return
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player
    }

    private var fileExtension: String {
        let type = contentType?.lowercased() ?? ""
        for (marker, ext) in [
            ("mp4", "mp4"), ("quicktime", "mov"), ("webm", "webm"),
            ("x-m4v", "m4v"), ("matroska", "mkv"),
            ("mpeg", "mp3"), ("aac", "m4a"), ("wav", "wav"), ("ogg", "ogg"),
        ] where type.contains(marker) {
            return ext
        }
        return isVideo ? "mp4" : "m4a"
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: DS.Space.x1 + 2) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(DS.Typography.ui(10.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DSColor.textMuted)
        .padding(.horizontal, DS.Space.x3)
        .frame(height: 22)
        .background(DSColor.sunken)
    }
}

/// Hosts `AVPlayerView` (native inline playback controls) inside SwiftUI.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
