import Foundation
import SwitchboardCore

/// Serves the line protocol on one Unix socket: sbd's own, or the socket of one remote host. Each connection
/// gets its own thread, so a slow request such as `new` does not hold up other clients. Every request of a
/// socket carries the socket's origin, which the connection can't change.
public final class Server {
  let service: Service
  let fd: Int32
  let origin: RequestOrigin
  /// The most bytes that a request line may hold, or nil for no limit.
  let maxLineBytes: Int?

  public convenience init(service: Service) throws {
    try self.init(service: service, path: service.home.socket, origin: .mac, maxLineBytes: nil)
  }

  init(service: Service, path: String, origin: RequestOrigin, maxLineBytes: Int?) throws {
    self.service = service
    self.origin = origin
    self.maxLineBytes = maxLineBytes
    self.fd = try UnixSocket.listen(path: path)
  }

  public func run() {
    Thread.detachNewThread { [self] in
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
          if errno != EINTR { logLine("accept: \(UnixSocket.errnoText())") }
          continue
        }
        Thread.detachNewThread { [self] in serve(client) }
      }
    }
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    if case .remote = origin { Server.limitSends(client, seconds: service.hostSendTimeoutSeconds) }
    let caller = Caller.client(pid: UnixSocket.peerPid(client))
    var reader = UnixSocket.LineReader(fd: client, maxLineBytes: maxLineBytes)
    while let line = try? reader.next() {
      if line.isEmpty { continue }
      var sent = false
      let send = { (response: Response) in
        guard var data = try? JSONCoding.encoder.encode(response) else {
          sent = false
          return
        }
        data.append(UInt8(ascii: "\n"))
        sent = (try? UnixSocket.write(client, data)) != nil
      }
      if let request = try? JSONCoding.decoder.decode(Request.self, from: line) {
        service.handle(
          request, origin: origin, caller: caller, hookGone: { UnixSocket.peerClosed(client) }, reply: send)
      } else {
        send(.failure("can't parse the request"))
      }
      guard sent else { return }
    }
  }

  /// A client on a host can stop reading its answers. A write to a client that reads nothing fails within twice
  /// the seconds: the first send returns what it sent so far, and the next one times out. `serve` then returns and
  /// closes the connection. It drops the answer that it couldn't send. A write to a closed client fails with EPIPE
  /// instead of raising SIGPIPE.
  static func limitSends(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  }
}
