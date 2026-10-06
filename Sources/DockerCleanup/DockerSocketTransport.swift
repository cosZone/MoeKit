import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DockerHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

protocol DockerTransport: Sendable {
    func identity(for endpoint: DockerEndpoint) throws -> DockerSocketIdentity
    func request(endpoint: DockerEndpoint, identity: DockerSocketIdentity, method: String,
                 path: String, cancellation: DockerCancellation) throws -> DockerHTTPResponse
}

/// A deliberately small HTTP client: local AF_UNIX only, no redirects, TLS, credentials,
/// subprocesses, context files, hooks or plugin loading. Called only from a detached task.
struct DockerSocketTransport: DockerTransport {
    let timeout: TimeInterval
    let maximumResponseBytes: Int
    init(timeout: TimeInterval = 30, maximumResponseBytes: Int = 16 * 1_024 * 1_024) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func identity(for endpoint: DockerEndpoint) throws -> DockerSocketIdentity {
        guard endpoint.socketPath.hasPrefix("/"), !endpoint.socketPath.contains("\0") else { throw DockerCleanupError.unsafeSocket }
        let resolved = URL(fileURLWithPath: endpoint.socketPath).resolvingSymlinksInPath().path
        var metadata = stat()
        guard resolved.withCString({ lstat($0, &metadata) }) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              metadata.st_uid == 0 || metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IWOTH)) == 0 else { throw DockerCleanupError.unsafeSocket }
        return DockerSocketIdentity(path: resolved, device: UInt64(metadata.st_dev),
                                    inode: UInt64(metadata.st_ino), owner: UInt32(metadata.st_uid))
    }

    func request(endpoint: DockerEndpoint, identity expected: DockerSocketIdentity, method: String,
                 path: String, cancellation: DockerCancellation) throws -> DockerHTTPResponse {
        try cancellation.check()
        guard try identity(for: endpoint) == expected, Self.allowed(method: method, path: path) else { throw DockerCleanupError.unsafeSocket }
        #if canImport(Darwin)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw DockerCleanupError.unavailable }
        defer { _ = close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw DockerCleanupError.unavailable }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw DockerCleanupError.unavailable }
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(expected.path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw DockerCleanupError.unsafeSocket }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw DockerCleanupError.unavailable }
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { throw DockerCleanupError.unavailable }
        }
        // A replacement at the original symlink or socket invalidates this connection too.
        guard try identity(for: endpoint) == expected else { throw DockerCleanupError.changed }
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            let count = request.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), request.count - sent, 0)
                #else
                Glibc.send(descriptor, buffer.baseAddress!.advanced(by: sent), request.count - sent, Int32(MSG_NOSIGNAL))
                #endif
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw DockerCleanupError.unavailable }
            sent += count
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count >= 0 else { throw DockerCleanupError.unavailable }
            if count == 0 { break }
            guard response.count <= maximumResponseBytes + 16_384 - count else { throw DockerCleanupError.responseTooLarge }
            response.append(contentsOf: buffer.prefix(count))
        }
        return try DockerHTTPParser.parse(response, maximumBodyBytes: maximumResponseBytes)
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval, cancellation: DockerCancellation) throws {
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DockerCleanupError.timeout }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&entry, 1, 100)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw DockerCleanupError.unavailable }
            if result > 0 {
                guard entry.revents & Int16(POLLNVAL) == 0 else { throw DockerCleanupError.unavailable }
                if entry.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
            }
        }
    }

    /// Defense in depth: production transport cannot issue unrelated Docker actions.
    static func allowed(method: String, path: String) -> Bool {
        if method == "GET" { return ["/version", "/v1.44/info", "/v1.44/system/df", "/v1.44/containers/json?all=1"].contains(path) }
        if method == "POST" { return path == "/v1.44/build/prune?all=true" }
        guard method == "DELETE" else { return false }
        if path.hasPrefix("/v1.44/images/"), path.hasSuffix("?force=false&noprune=true") {
            return DockerValidation.imageID(String(path.dropFirst("/v1.44/images/".count).dropLast("?force=false&noprune=true".count)))
        }
        if path.hasPrefix("/v1.44/containers/"), path.hasSuffix("?force=false&v=false") {
            return DockerValidation.containerID(String(path.dropFirst("/v1.44/containers/".count).dropLast("?force=false&v=false".count)))
        }
        return false
    }
}

enum DockerHTTPParser {
    static func parse(_ data: Data, maximumBodyBytes: Int) throws -> DockerHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: separator), split.lowerBound <= 16_384,
              let header = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw DockerCleanupError.malformedResponse }
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = (lines.first ?? "").split(separator: " ")
        guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(statusLine[0])),
              let status = Int(statusLine[1]), (200...599).contains(status) else { throw DockerCleanupError.malformedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw DockerCleanupError.malformedResponse }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw DockerCleanupError.malformedResponse }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[split.upperBound...])
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw DockerCleanupError.malformedResponse }
            return DockerHTTPResponse(status: status, body: try chunks(body, limit: maximumBodyBytes))
        }
        if let length = headers["content-length"] {
            guard let size = Int(length), size >= 0, size == body.count else { throw DockerCleanupError.malformedResponse }
        }
        guard body.count <= maximumBodyBytes else { throw DockerCleanupError.responseTooLarge }
        return DockerHTTPResponse(status: status, body: body)
    }

    private static func chunks(_ input: Data, limit: Int) throws -> Data {
        let bytes = Array(input)
        var cursor = 0
        var result = Data()
        while cursor < bytes.count {
            let start = cursor
            while cursor + 1 < bytes.count && !(bytes[cursor] == 13 && bytes[cursor + 1] == 10) { cursor += 1 }
            guard cursor + 1 < bytes.count, cursor - start <= 32,
                  let line = String(bytes: bytes[start..<cursor], encoding: .ascii),
                  !line.isEmpty, line.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(line, radix: 16), size >= 0 else { throw DockerCleanupError.malformedResponse }
            cursor += 2
            guard size <= limit - result.count else { throw DockerCleanupError.responseTooLarge }
            guard size <= bytes.count - cursor - 2 else { throw DockerCleanupError.malformedResponse }
            if size == 0 {
                guard cursor + 2 == bytes.count, bytes[cursor] == 13, bytes[cursor + 1] == 10 else { throw DockerCleanupError.malformedResponse }
                return result
            }
            result.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size
            guard bytes[cursor] == 13, bytes[cursor + 1] == 10 else { throw DockerCleanupError.malformedResponse }
            cursor += 2
        }
        throw DockerCleanupError.malformedResponse
    }
}
