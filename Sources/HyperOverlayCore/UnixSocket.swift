import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case socketFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .socketFailed(let code):
            return "socket failed: \(String(cString: strerror(code)))"
        case .connectFailed(let code):
            return "connect failed: \(String(cString: strerror(code)))"
        case .bindFailed(let code):
            return "bind failed: \(String(cString: strerror(code)))"
        case .listenFailed(let code):
            return "listen failed: \(String(cString: strerror(code)))"
        case .acceptFailed(let code):
            return "accept failed: \(String(cString: strerror(code)))"
        case .writeFailed(let code):
            return "write failed: \(String(cString: strerror(code)))"
        case .readFailed(let code):
            return "read failed: \(String(cString: strerror(code)))"
        case .timeout:
            return "socket read timed out"
        }
    }
}

public enum UnixSocket {
    /// Validates a Unix-domain socket path without opening or binding a socket.
    /// Runtime callers use this during configuration and tests so an invalid path
    /// fails before it can affect an existing listener.
    public static func validatePath(_ path: String) throws {
        _ = try socketAddress(path: path)
    }

    public static func connect(path: String, timeoutSeconds: Int = 2) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(errno: errno) }

        do {
            try configureTimeout(fd: fd, timeoutSeconds: timeoutSeconds)
            var address = try socketAddress(path: path)
            let length = socketLength(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, length)
                }
            }
            guard result == 0 else {
                let code = errno
                close(fd)
                throw UnixSocketError.connectFailed(errno: code)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func bindListener(path: String, backlog: Int32 = 16) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(errno: errno) }

        do {
            _ = unlink(path)
            var address = try socketAddress(path: path)
            let length = socketLength(path: path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, length)
                }
            }
            guard bindResult == 0 else {
                let code = errno
                close(fd)
                throw UnixSocketError.bindFailed(errno: code)
            }
            guard listen(fd, backlog) == 0 else {
                let code = errno
                close(fd)
                throw UnixSocketError.listenFailed(errno: code)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func accept(listener: Int32, timeoutSeconds: Int = 2) throws -> Int32 {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { throw UnixSocketError.acceptFailed(errno: errno) }
        do {
            try configureTimeout(fd: fd, timeoutSeconds: timeoutSeconds)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: sent), data.count - sent)
                if result < 0 {
                    throw UnixSocketError.writeFailed(errno: errno)
                }
                sent += result
            }
        }
    }

    public static func readLine(fd: Int32, maxBytes: Int = 1_048_576) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while data.count < maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw UnixSocketError.timeout
                }
                throw UnixSocketError.readFailed(errno: errno)
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(buffer, count: newline)
                return data
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func configureTimeout(fd: Int32, timeoutSeconds: Int) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rawPointer in
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rawPointer, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        if result != 0 {
            throw UnixSocketError.socketFailed(errno: errno)
        }
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw UnixSocketError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for index in 0..<capacity {
                    buffer[index] = 0
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bytes[index])
                }
            }
        }
        return address
    }

    private static func socketLength(path: String) -> socklen_t {
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        return socklen_t(offset + path.utf8CString.count)
    }
}
