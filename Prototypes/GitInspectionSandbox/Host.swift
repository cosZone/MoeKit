import Foundation
import Darwin

@main enum ProbeHost {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { exit(64) }
        let selected = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let mode = arguments[3]
        var bookmark = Data()
        switch mode {
        case "implicit":
            bookmark = try selected.bookmarkData(options: [])
        case "downgraded":
            let scoped = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
            var stale = false
            let resolved = try URL(resolvingBookmarkData: scoped, options: [.withSecurityScope],
                                   bookmarkDataIsStale: &stale)
            guard !stale else { exit(65) }
            _ = resolved.startAccessingSecurityScopedResource()
            bookmark = try resolved.bookmarkData(options: [])
        case "descriptor": break
        default: exit(64)
        }
        let connection = NSXPCConnection(serviceName: "com.yusixian.MoeKit.GitSandboxProbe.Service")
        connection.remoteObjectInterface = NSXPCInterface(with: GitSandboxProbeProtocol.self)
        connection.interruptionHandler = { fputs("XPC interrupted\n", stderr); exit(70) }
        connection.invalidationHandler = { fputs("XPC invalidated before reply\n", stderr); exit(71) }
        connection.resume()
        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            fputs("XPC error: \(error.localizedDescription)\n", stderr); exit(72)
        }) as? GitSandboxProbeProtocol else { exit(73) }
        let reply: (Data) -> Void = { data in
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            exit(0)
        }
        if mode == "descriptor" {
            let fd = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { exit(76) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            service.probeDescriptor(directory: handle, selectedPath: selected.path,
                                    outsidePath: arguments[2], reply: reply)
        } else {
            service.probe(bookmark: bookmark, selectedPath: selected.path, outsidePath: arguments[2], reply: reply)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(74) }
        dispatchMain()
    }
}
