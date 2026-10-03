/// Interactive viewing favors fresh frames so PTZ movement is visible promptly.
/// A wall of independent streams retains the larger buffer for scheduling jitter.
enum PlaybackProfile: Sendable {
    case interactive
    case dashboard

    var mediaOptions: [String] {
        switch self {
        case .interactive:
            // VLC's live555 demuxer uses network-caching as its PTS delay.
            // Bound extra clock compensation; retain normal A/V synchronization.
            [":network-caching=100", ":clock-jitter=100"]
        case .dashboard:
            [":network-caching=500"]
        }
    }
}
