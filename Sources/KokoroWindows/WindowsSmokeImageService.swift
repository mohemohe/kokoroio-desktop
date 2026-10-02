import Foundation
import KokoroCore
import KokoroWindowsState

/// Deterministic image operations for the app's explicit --smoke-test mode.
/// Uploads use no URLSession or HTTP request.
actor WindowsSmokeImageService: WindowsImageService {
    private var uploads: [CheckedContinuation<ImageUpload, Error>] = []
    private var isShutDown = false

    private(set) var uploadCount = 0
    var pendingUploadCount: Int { uploads.count }

    init() {
        precondition(CommandLine.arguments.contains("--smoke-test"),
                     "WindowsSmokeImageService is only available in explicit smoke-test mode")
    }

    func uploadImage(data: Data, fileName: String, mimeType: String) async throws -> ImageUpload {
        guard !isShutDown else { throw CancellationError() }
        guard !data.isEmpty else { throw ImageUploadError.invalidImage }
        uploadCount += 1
        return try await withCheckedThrowingContinuation { uploads.append($0) }
    }

    /// Resolve the oldest pending upload once the store reaches this service.
    @discardableResult
    func completeNext() -> Bool {
        guard !uploads.isEmpty else { return false }
        uploads.removeFirst().resume(returning: Self.result)
        return true
    }

    @discardableResult
    func failNext() -> Bool {
        guard !uploads.isEmpty else { return false }
        uploads.removeFirst().resume(throwing: APIError.server(status: 503, message: "Fixture upload failed"))
        return true
    }

    /// Finish every continuation even if a smoke assertion aborts a scenario.
    func shutdown() {
        isShutDown = true
        let pendingUploads = uploads
        uploads.removeAll()
        pendingUploads.forEach { $0.resume(throwing: CancellationError()) }
    }

    private static let result = ImageUpload(signedID: "smoke-image-signed-id", contentType: "image/bmp", animated: false)
}
