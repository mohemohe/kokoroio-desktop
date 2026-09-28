import Foundation
@_spi(WinRTInternal) @_spi(WinRTImplements) import WinUI
import WinAppSDK
import WindowsNative
@_spi(WinRTImplements) import WindowsFoundation

// Register WinUI's metadata provider for its standard control resources.
final class KokoroApplication: Application, IXamlMetadataProvider {
    private lazy var metadata = XamlControlsXamlMetaDataProvider()
    override func queryInterface(_ iid: WindowsFoundation.IID) -> IUnknownRef? {
        if iid == __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper.IID {
            return __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper(self)?.queryInterface(iid)
        }
        return super.queryInterface(iid)
    }
    func getXamlType(_ type: TypeName) throws -> AnyIXamlType! { try metadata.getXamlType(type) }
    func getXamlType(_ fullName: String) throws -> AnyIXamlType! { try metadata.getXamlType(fullName) }
    func getXmlnsDefinitions() throws -> [XmlnsDefinition] { try metadata.getXmlnsDefinitions() }
}

@main
struct KokoroDesktop {
    @MainActor
    static func main() {
        let result = KokoroInitializeRuntime()
        guard result >= 0 else {
            fputs("Windows App Runtime 1.7 (x64) is required. HRESULT: \(String(UInt32(bitPattern: result), radix: 16))\n", stderr)
            KokoroShutdownRuntime()
            exit(1)
        }
        defer { KokoroShutdownRuntime() }
        do {
            // WinUI and Swift concurrency share the same UI thread. Pump both queues;
            // Application.start alone does not service DispatchQueue.main on Windows.
            let queue = try DispatcherQueueController.createOnCurrentThread()
            let application = KokoroApplication()
            let xaml = try WindowsXamlManager.initializeForCurrentThread()
            application.dispatcherShutdownMode = .onLastWindowClose
            application.resources.mergedDictionaries.append(XamlControlsResources())
            let workspace = WorkspaceWindow()
            try workspace.show()
            withExtendedLifetime((queue, application, xaml, workspace)) {
                while !workspace.isClosed && KokoroPumpMessages() != 0 {
                    _ = RunLoop.main.limitDate(forMode: .default)
                    KokoroWaitForMessages()
                }
                workspace.shutdown()
            }
        } catch {
            fputs("Kokoro Desktop could not start: \(error)\n", stderr)
            exit(1)
        }
    }
}
