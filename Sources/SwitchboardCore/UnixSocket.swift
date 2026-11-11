import Foundation

/// Blocking Unix domain socket calls for sbd's line protocol.
public enum UnixSocket {
  public static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw APIError("socket: \(errnoText())") }
    do {
      let rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
      guard rc == 0 else { throw APIError("can't reach sbd at \(path): \(errnoText())") }
      configure(fd, timeout: timeout)
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  /// Binds and listens on `path`, replacing a stale socket file.
  public static func listen(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw APIError("socket: \(errnoText())") }
    unlink(path)
    do {
      guard try withAddress(path, { bind(fd, $0, $1) }) == 0 else {
        throw APIError("can't bind \(path): \(errnoText())")
      }
      chmod(path, 0o600)
      guard Darwin.listen(fd, 64) == 0 else { throw APIError("can't listen on \(path): \(errnoText())") }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  /// Sets the read and write timeout, and makes a write to a closed peer
  /// fail with EPIPE instead of raising SIGPIPE.
  public static func configure(_ fd: Int32, timeout: TimeInterval) {
    var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }

  /// Whether the peer closed its end of the connection. It doesn't block.
  public static func peerClosed(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
  }

  public static func write(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          throw APIError("write: \(errnoText())")
        }
        offset += n
      }
    }
  }

  /// Reads newline-terminated lines from a socket.
  public struct LineReader {
    let fd: Int32
    var buffer = Data()
    /// How many bytes at the start of `buffer` hold no newline. A long line,
    /// such as a request with an image, then takes one scan.
    var scanned = 0
    var chunk = [UInt8](repeating: 0, count: 65536)
    /// The most bytes that a line may hold, or nil for no limit.
    let maxLineBytes: Int?

    public init(fd: Int32, maxLineBytes: Int? = nil) {
      self.fd = fd
      self.maxLineBytes = maxLineBytes
    }

    /// The next line, without its newline, or nil at the end of the stream.
    public mutating func next() throws -> Data? {
      while true {
        if let i = buffer[(buffer.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
          let line = Data(buffer[buffer.startIndex..<i])
          buffer = Data(buffer[(i + 1)...])
          scanned = 0
          return line
        }
        scanned = buffer.count
        if let maxLineBytes, scanned > maxLineBytes { throw APIError("a line holds more than \(maxLineBytes) bytes") }
        let n = read(fd, &chunk, chunk.count)
        if n == 0 {
          guard !buffer.isEmpty else { return nil }
          let rest = buffer
          buffer = Data()
          scanned = 0
          return rest
        }
        if n < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { throw APIError("sbd did not answer in time") }
          throw APIError("read: \(errnoText())")
        }
        buffer.append(contentsOf: chunk[0..<n])
      }
    }
  }

  /// Calls `body` with the socket address of `path`. It throws for a path that is too long for one.
  public static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32
  {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw APIError("socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
  }

  public static func errnoText() -> String { String(cString: strerror(errno)) }
}
