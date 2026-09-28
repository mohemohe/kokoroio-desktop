import Foundation
import KokoroCore
import KokoroWindowsState

/// Deterministic image operations for the app's explicit --smoke-test mode.
/// No URLSession, HTTP request, real ImgBB key, or remote deletion is used.
actor WindowsSmokeImageService: WindowsImageService {
    private var uploads: [CheckedContinuation<ImgBBUpload, Error>] = []
    private var deletions: [CheckedContinuation<Void, Error>] = []
    private var isShutDown = false

    private(set) var uploadCount = 0
    private(set) var deletionCount = 0
    var pendingUploadCount: Int { uploads.count }
    var pendingDeleteCount: Int { deletions.count }

    init() {
        precondition(CommandLine.arguments.contains("--smoke-test"),
                     "WindowsSmokeImageService is only available in explicit smoke-test mode")
    }

    func upload(data: Data, fileName: String, mimeType: String, apiKey: String) async throws -> ImgBBUpload {
        guard !isShutDown else { throw CancellationError() }
        guard !data.isEmpty else { throw ImgBBError.invalidImage }
        uploadCount += 1
        return try await withCheckedThrowingContinuation { uploads.append($0) }
    }

    func delete(_ upload: ImgBBUpload, apiKey: String) async throws {
        guard !isShutDown else { throw CancellationError() }
        deletionCount += 1
        try await withCheckedThrowingContinuation { deletions.append($0) }
    }

    /// Resolve the oldest pending upload. False means the store has not reached
    /// this service yet; the caller should await pendingUploadCount before use.
    @discardableResult
    func completeNext() -> Bool {
        guard !uploads.isEmpty else { return false }
        uploads.removeFirst().resume(returning: Self.result)
        return true
    }

    @discardableResult
    func failNext() -> Bool {
        guard !uploads.isEmpty else { return false }
        uploads.removeFirst().resume(throwing: ImgBBError.server(503))
        return true
    }

    @discardableResult
    func completeNextDelete() -> Bool {
        guard !deletions.isEmpty else { return false }
        deletions.removeFirst().resume(returning: ())
        return true
    }

    @discardableResult
    func failNextDelete() -> Bool {
        guard !deletions.isEmpty else { return false }
        deletions.removeFirst().resume(throwing: ImgBBError.server(503))
        return true
    }

    /// Finish every continuation even if a smoke assertion aborts a scenario.
    /// Future cleanup operations immediately cancel rather than remaining suspended.
    func shutdown() {
        isShutDown = true
        let pendingUploads = uploads
        let pendingDeletions = deletions
        uploads.removeAll()
        deletions.removeAll()
        pendingUploads.forEach { $0.resume(throwing: CancellationError()) }
        pendingDeletions.forEach { $0.resume(throwing: CancellationError()) }
    }

    private static let result = ImgBBUpload(
        url: URL(string: "http://127.0.0.1:8765/test/images/124-0-thumb.png")!,
        deleteURL: URL(string: "http://127.0.0.1:8765/test/smoke-image-delete")!
    )
}
