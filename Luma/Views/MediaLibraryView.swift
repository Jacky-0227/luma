import Observation
import SwiftUI
import UIKit

@MainActor
struct MediaLibraryView: View {
    let library: MediaLibrary
    @State private var selectedItem: CapturedMedia?
    @State private var itemToDelete: CapturedMedia?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No captures yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Save snapshots or recordings from live view.")
                    }
                } else {
                    List(library.items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: item.kind == .snapshot ? "photo" : "play.rectangle")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 46, height: 46)
                                    .background(.tint.opacity(0.08), in: .rect(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.kind.title).font(.headline).foregroundStyle(.primary)
                                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.item.\(item.id.uuidString)")
                        .swipeActions {
                            Button("Delete", role: .destructive) { itemToDelete = item }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { itemToDelete = item }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                if let message = library.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .sheet(item: $selectedItem) { item in
                if let url = library.fileURL(for: item) {
                    MediaPreview(item: item, url: url)
                } else {
                    ContentUnavailableView("File unavailable", systemImage: "doc.questionmark")
                }
            }
            .confirmationDialog("Delete this item?", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ), titleVisibility: .visible, presenting: itemToDelete) { item in
                Button("Delete", role: .destructive) {
                    do { try library.delete(item) }
                    catch { errorMessage = MediaLibraryError.deleteFailed.localizedDescription }
                    itemToDelete = nil
                }
                Button("Cancel", role: .cancel) { itemToDelete = nil }
            } message: { _ in
                Text("The file will be permanently removed from this device.")
            }
            .alert("Media library", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            // The library loads its index once and publishes every capture or
            // deletion. Tab switches must not repeat a full synchronous disk scan.
        }
    }
}

private struct MediaPreview: View {
    @Environment(\.dismiss) private var dismiss
    let item: CapturedMedia
    let url: URL

    var body: some View {
        NavigationStack {
            Group {
                if item.kind == .snapshot {
                    SnapshotPreview(url: url)
                } else {
                    RecordingPreview(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .navigationTitle(item.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SnapshotPreview: View {
    let url: URL
    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(Text("Snapshot"))
            } else if didLoad {
                ContentUnavailableView("File unavailable", systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            image = nil
            didLoad = false
            let thumbnail = await SnapshotThumbnailLoader.shared.load(url: url)
            guard !Task.isCancelled else { return }
            image = thumbnail.map { UIImage(cgImage: $0.image) }
            didLoad = true
        }
    }
}

private struct RecordingPreview: View {
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    @State private var playback = LocalClipPlayback()

    var body: some View {
        VStack(spacing: 20) {
            LocalClipSurface(playback: playback)
            if let error = playback.error {
                Text(error).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
            }
            Button {
                if playback.isPlaying { playback.stop() } else { playback.play(url) }
            } label: {
                Label(playback.isPlaying ? String(localized: "Stop") : String(localized: "Play recording"),
                      systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .padding(.bottom)
        }
        .onAppear { if scenePhase == .active { playback.play(url) } }
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.stop() }
        }
    }
}

/// VLC handles the actual camera muxer output (including TS and MKV), without
/// pretending every recorded stream is an AVPlayer-compatible MP4.
@MainActor
@Observable
private final class LocalClipPlayback {
    private(set) var isPlaying = false
    private(set) var error: String?
    @ObservationIgnored private weak var surface: UIView?
    @ObservationIgnored private var session: VLCPlaybackSession?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var isClosing = false

    deinit {
        let orphan = session
        Task { @MainActor in orphan?.retire() }
    }

    func attach(_ view: UIView) {
        surface = view
        beginIfReady()
    }

    func play(_ url: URL) {
        guard url.isFileURL else { return }
        pendingURL = url
        error = nil
        beginIfReady()
    }

    func stop() {
        pendingURL = nil
        isPlaying = false
        guard let old = session else { return }
        session = nil
        isClosing = true
        old.retire { [weak self] in
            self?.isClosing = false
            self?.beginIfReady()
        }
    }

    private func beginIfReady() {
        guard session == nil, !isClosing, let pendingURL, let surface else { return }
        let next = VLCPlaybackSession(url: pendingURL, useTCP: false)
        session = next
        let id = next.id
        next.onEvent = { [weak self] event in
            guard let self, self.session?.id == id else { return }
            switch event {
            case .videoPlaying: self.isPlaying = true
            case .ended: self.stop()
            case .failed:
                self.stop()
                self.error = String(localized: "This recording could not be played.")
            default: break
            }
        }
        next.start(on: surface, muted: false, aspectFill: false)
    }
}

private struct LocalClipSurface: UIViewRepresentable {
    let playback: LocalClipPlayback

    func makeCoordinator() -> LocalClipPlayback { playback }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = true
        playback.attach(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: LocalClipPlayback) { coordinator.stop() }
}
