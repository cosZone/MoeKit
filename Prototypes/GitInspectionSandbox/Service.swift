import Foundation
import Darwin

// Every path passed to this experimental process is a unique synthetic fixture.
// Never import this probe into the production app; it intentionally tries writes.
final class ProbeService: NSObject, GitSandboxProbeProtocol {
    func probeDescriptor(directory: FileHandle, selectedPath: String, outsidePath: String,
                         reply: @escaping (Data) -> Void) {
        let fd = directory.fileDescriptor
        let readFD = openat(fd, "sentinel", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        let readAllowed = readFD >= 0
        if readFD >= 0 { close(readFD) }
        let writeFD = openat(fd, "write-probe", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        let writeDenied = writeFD < 0
        if writeFD >= 0 { close(writeFD) }
        let escapeFD = openat(fd, "escape/sentinel", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        let escapeDenied = escapeFD < 0
        if escapeFD >= 0 { close(escapeFD) }
        let outside = URL(fileURLWithPath: outsidePath, isDirectory: true)
        let values = ["resolvedSelectedPath": true, "selectedReadAllowed": readAllowed,
                      "selectedWriteDenied": writeDenied, "symlinkEscapeReadDenied": escapeDenied,
                      "outsideReadDenied": !canRead(outside.appendingPathComponent("sentinel")),
                      "outsideWriteDenied": !canWrite(outside.appendingPathComponent("write-probe"))]
        reply((try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data())
    }

    func probe(bookmark: Data, selectedPath: String, outsidePath: String,
               reply: @escaping (Data) -> Void) {
        var values: [String: Any] = [:]
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)
            defer { url.stopAccessingSecurityScopedResource() }
            values["resolvedSelectedPath"] = url.standardizedFileURL == URL(fileURLWithPath: selectedPath, isDirectory: true).standardizedFileURL
            values["selectedReadAllowed"] = canRead(url.appendingPathComponent("sentinel"))
            values["selectedWriteDenied"] = !canWrite(url.appendingPathComponent("write-probe"))
            let outside = URL(fileURLWithPath: outsidePath, isDirectory: true)
            values["outsideReadDenied"] = !canRead(outside.appendingPathComponent("sentinel"))
            values["outsideWriteDenied"] = !canWrite(outside.appendingPathComponent("write-probe"))
            values["symlinkEscapeReadDenied"] = !canRead(url.appendingPathComponent("escape/sentinel"))
        } catch {
            values["bookmarkError"] = error.localizedDescription
        }
        reply((try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data())
    }

    private func canRead(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) == 1
    }

    private func canWrite(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}

final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    private var used = false
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !used else { return false }
        used = true
        connection.exportedInterface = NSXPCInterface(with: GitSandboxProbeProtocol.self)
        connection.exportedObject = ProbeService()
        connection.invalidationHandler = { _exit(0) }
        connection.resume()
        return true
    }
}

@main enum ProbeMain {
    static func main() {
        let delegate = ProbeDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { _exit(75) }
        withExtendedLifetime(delegate) { listener.resume() }
    }
}
