import Foundation
import UWP
import WinUI
import WindowsFoundation

/// Captures only this app's XAML surface for reproducible fixture-based visual review.
@MainActor
enum WindowsUISnapshot {
    static func capture(_ element: FrameworkElement, to url: URL) async throws {
        try element.updateLayout()
        let bitmap = RenderTargetBitmap()
        try await bitmap.renderAsync(element).get()
        guard let pixels = try await bitmap.getPixelsAsync().get() else { return }
        var bytes = [UInt8](repeating: 0, count: Int(pixels.length))
        let reader = try DataReader.fromBuffer(pixels)!
        try reader.readBytes(&bytes)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt16(0x4d42)); append(UInt32(54 + bytes.count)); append(UInt32(0)); append(UInt32(54))
        append(UInt32(40)); append(bitmap.pixelWidth); append(-bitmap.pixelHeight)
        append(UInt16(1)); append(UInt16(32)); append(UInt32(0)); append(UInt32(bytes.count))
        append(Int32(2835)); append(Int32(2835)); append(UInt32(0)); append(UInt32(0))
        data.append(contentsOf: bytes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
