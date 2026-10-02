import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UIKit

enum DashboardSnapshotRequest {
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumPixelSize = 480

    static func make(for configuration: CameraConfiguration) throws -> URLRequest {
        let camera = try configuration.validated()
        // A custom RTSP path may identify a different input or vendor. Never
        // put a default-channel image on that camera's card.
        guard camera.customPath.isEmpty else { throw PTZError.unsupported }
        let endpoint = try PTZEndpoint(configuration: camera, requireEnabled: false)
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        // ISAPI streaming IDs encode the video input and main-stream suffix.
        // Do not guess /1 on failure: on a recorder that could be another input.
        let stream = camera.channel * 100 + 1
        guard let url = URL(string: "\(endpoint.scheme)://\(host):\(endpoint.port)/ISAPI/Streaming/channels/\(stream)/picture") else {
            throw PTZError.invalidSettings
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        return request
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.expectedContentLength <= Int64(maximumBytes) else { throw PTZError.invalidResponse }
    }
}

/// Network iteration and ImageIO decoding run outside the UI executor. Only
/// bounded JPEG data and an immutable decoded CGImage cross this actor boundary.
actor DashboardPreviewLoader {
    static let shared = DashboardPreviewLoader()

    func download(configuration: CameraConfiguration, password: String) async throws -> Data {
        try Task.checkCancellation()
        let endpoint = try PTZEndpoint(configuration: configuration, requireEnabled: false)
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = 3
        settings.timeoutIntervalForResource = 5
        settings.httpMaximumConnectionsPerHost = 1
        let authentication = PTZAuthenticationDelegate(endpoint: endpoint, username: configuration.username, password: password)
        let session = URLSession(configuration: settings, delegate: authentication, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: DashboardSnapshotRequest.make(for: configuration))
        try DashboardSnapshotRequest.validate(response)
        var body = Data()
        if response.expectedContentLength > 0 { body.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard body.count < DashboardSnapshotRequest.maximumBytes else { throw PTZError.invalidResponse }
            if body.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            body.append(byte)
        }
        try Task.checkCancellation()
        return body
    }

    func decode(_ data: Data) -> SnapshotThumbnail? {
        guard !Task.isCancelled, data.count >= 3, data.count <= DashboardSnapshotRequest.maximumBytes,
              data.starts(with: [0xff, 0xd8, 0xff]) else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              width * height <= 64_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: DashboardSnapshotRequest.maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return SnapshotThumbnail(image: image)
    }
}

private final class DashboardPreviewCancellation: @unchecked Sendable {
    private let state = Mutex(false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// The overview shares a small, ephemeral JPEG cache. It never starts VLC,
/// records media, or writes preview images or credentials to disk.
@MainActor
final class DashboardPreviewService {
    static let shared = DashboardPreviewService()
    typealias Fetch = @MainActor (CameraConfiguration, String) async throws -> Data
    private struct Entry {
        let image: UIImage?
        let expires: Date
        var access: UInt64
    }
    private struct Waiter {
        let continuation: CheckedContinuation<UIImage?, Never>
        let cancellation: DashboardPreviewCancellation
    }
    private final class Job {
        let id = UUID()
        let camera: CameraConfiguration
        let password: String
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        init(camera: CameraConfiguration, password: String) {
            self.camera = camera
            self.password = password
        }
    }
    private let fetch: Fetch
    private let now: @MainActor () -> Date
    private var cache: [String: Entry] = [:]
    private var pending: [String: Job] = [:]
    private var queue: [String] = []
    private var active = 0
    private var access: UInt64 = 0

    init(fetch: @escaping Fetch = { camera, password in
        try await DashboardPreviewLoader.shared.download(configuration: camera, password: password)
    }, now: @escaping @MainActor () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    static func cacheKey(for camera: CameraConfiguration) -> String {
        let parts = [camera.id.uuidString, camera.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                     String(camera.controlPort), String(camera.controlUseHTTPS), camera.username,
                     String(camera.channel), camera.customPath]
        let encoded = (try? JSONEncoder().encode(parts)) ?? Data()
        return digest(encoded)
    }

    func image(for camera: CameraConfiguration, password: String) async -> UIImage? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return nil }
        #endif
        guard !Task.isCancelled, let camera = try? camera.validated(), camera.customPath.isEmpty else { return nil }
        let key = Self.cacheKey(for: camera) + Self.digest(Data(password.utf8))
        access &+= 1
        if var entry = cache[key], entry.expires > now() {
            entry.access = access
            cache[key] = entry
            return entry.image
        }
        let waiterID = UUID()
        let cancellation = DashboardPreviewCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                let waiter = Waiter(continuation: continuation, cancellation: cancellation)
                if let job = pending[key], job.task?.isCancelled != true { job.waiters[waiterID] = waiter }
                else {
                    let job = Job(camera: camera, password: password)
                    job.waiters[waiterID] = waiter
                    pending[key] = job
                    queue.append(key)
                }
                drain()
            }
        } onCancel: {
            // This bit is visible before a queued job can create its socket,
            // even if MainActor has not processed the cleanup callback yet.
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(waiterID, key: key) }
        }
    }

    private func cancel(_ waiterID: UUID, key: String) {
        guard let job = pending[key], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: nil)
        if job.waiters.isEmpty {
            if let task = job.task { task.cancel() }
            else {
                pending[key] = nil
                queue.removeAll { $0 == key }
            }
        }
        drain()
    }

    private func removeCancelledWaiters(from job: Job) {
        for (id, waiter) in job.waiters where waiter.cancellation.isCancelled {
            job.waiters[id] = nil
            waiter.continuation.resume(returning: nil)
        }
    }

    private func drain() {
        while active < 2, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = pending[key] else { continue }
            removeCancelledWaiters(from: job)
            guard !job.waiters.isEmpty else { pending[key] = nil; continue }
            active += 1
            job.task = Task { @MainActor [self, job] in
                removeCancelledWaiters(from: job)
                guard !Task.isCancelled, !job.waiters.isEmpty else { finish(key: key, job: job, image: nil, cacheResult: false); return }
                var image: UIImage?
                do {
                    let data = try await fetch(job.camera, job.password)
                    try Task.checkCancellation()
                    if let decoded = await DashboardPreviewLoader.shared.decode(data) {
                        image = UIImage(cgImage: decoded.image)
                    }
                    try Task.checkCancellation()
                } catch { image = nil }
                finish(key: key, job: job, image: image, cacheResult: !Task.isCancelled)
            }
        }
    }

    private func finish(key: String, job: Job, image: UIImage?, cacheResult: Bool) {
        active -= 1
        let current = pending[key]?.id == job.id
        if current { pending[key] = nil }
        if current, cacheResult, job.waiters.values.contains(where: { !$0.cancellation.isCancelled }) {
            access &+= 1
            if cache.count >= 64, cache[key] == nil, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
                cache[oldest] = nil
            }
            cache[key] = Entry(image: image, expires: now().addingTimeInterval(60), access: access)
        }
        let waiters = Array(job.waiters.values)
        job.waiters = [:]
        for waiter in waiters { waiter.continuation.resume(returning: waiter.cancellation.isCancelled ? nil : image) }
        drain()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
