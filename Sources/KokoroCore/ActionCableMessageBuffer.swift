import Foundation

/// corelibs FoundationNetworking can deliver a curl receive chunk as a WebSocket
/// message on Windows. Frame the ActionCable JSON objects before decoding them.
/// Keep bytes intact until the whole object is available, including JSON escapes.
struct ActionCableMessageBuffer {
    enum Failure: Error { case invalidMessage, messageTooLarge }

    static let maximumMessageBytes = 8 * 1_024 * 1_024
    private let maximumBytes: Int
    private var bytes: [UInt8] = []
    private var scanned = 0
    private var start: Int?
    private var depth = 0
    private var inString = false
    private var escaped = false

    init(maximumBytes: Int = maximumMessageBytes) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ data: Data) throws -> [ActionCableProtocol.Frame] {
        do {
            guard data.count <= maximumBytes - bytes.count else { throw Failure.messageTooLarge }
            bytes.append(contentsOf: data)
            var frames: [ActionCableProtocol.Frame] = []
            var consumed = 0
            while scanned < bytes.count {
                let index = scanned, byte = bytes[index]
                scanned += 1
                if start == nil {
                    if [UInt8(0x20), 0x09, 0x0A, 0x0D].contains(byte) { consumed = scanned; continue }
                    guard byte == 0x7B else { throw Failure.invalidMessage } // {
                    start = index
                }
                if inString {
                    if escaped { escaped = false }
                    else if byte == 0x5C { escaped = true } // backslash
                    else if byte == 0x22 { inString = false }
                } else {
                    switch byte {
                    case 0x22: inString = true
                    case 0x7B, 0x5B: depth += 1 // { [
                    case 0x7D, 0x5D: depth -= 1 // } ]
                    default: break
                    }
                    if depth == 0, let start {
                        frames.append(try ActionCableProtocol.parse(Data(bytes[start...index])))
                        self.start = nil
                        consumed = scanned
                    }
                }
            }
            if consumed > 0 {
                bytes.removeFirst(consumed)
                scanned -= consumed
                if let start { self.start = start - consumed }
            }
            return frames
        } catch {
            self = Self(maximumBytes: maximumBytes)
            throw error
        }
    }
}
