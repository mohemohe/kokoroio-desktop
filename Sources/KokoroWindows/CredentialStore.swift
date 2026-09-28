import Foundation
import WindowsNative

struct WindowsCredential: Codable {
    let server: String
    let token: String
}

enum WindowsCredentialStore {
    struct Failure: LocalizedError {
        let code: UInt32
        var errorDescription: String? { "Windows 資格情報マネージャーにアクセスできませんでした (\(code))。" }
    }
    static func load() throws -> WindowsCredential? {
        var bytes = [UInt8](repeating: 0, count: 2560)
        var count: UInt32 = 0
        let result = KokoroLoadCredential(&bytes, UInt32(bytes.count), &count)
        if result == 1168 { return nil } // ERROR_NOT_FOUND
        guard result == 0 else { throw Failure(code: result) }
        return try JSONDecoder().decode(WindowsCredential.self, from: Data(bytes.prefix(Int(count))))
    }
    static func save(_ credential: WindowsCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let result = data.withUnsafeBytes { KokoroSaveCredential($0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count)) }
        guard result == 0 else { throw Failure(code: result) }
    }
    static func delete() throws {
        let result = KokoroDeleteCredential()
        guard result == 0 else { throw Failure(code: result) }
    }
}

/// Image-host credentials must never overwrite the kokoro.io login credential.
enum WindowsImgBBKeyStore {
    static func load() throws -> String? {
        var bytes = [UInt8](repeating: 0, count: 2560)
        var count: UInt32 = 0
        let result = KokoroLoadImgBBKey(&bytes, UInt32(bytes.count), &count)
        if result == 1168 { return nil } // ERROR_NOT_FOUND
        guard result == 0 else { throw WindowsCredentialStore.Failure(code: result) }
        guard let value = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else {
            throw WindowsCredentialStore.Failure(code: 13) // ERROR_INVALID_DATA
        }
        return value
    }

    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try delete(); return }
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBufferPointer { KokoroSaveImgBBKey($0.baseAddress, UInt32($0.count)) }
        guard result == 0 else { throw WindowsCredentialStore.Failure(code: result) }
    }

    static func delete() throws {
        let result = KokoroDeleteImgBBKey()
        guard result == 0 else { throw WindowsCredentialStore.Failure(code: result) }
    }
}
