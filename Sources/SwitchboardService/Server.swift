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
    let caller = Caller.client(pid: UnixSocket.peerPid(client))
    var reader = UnixSocket.LineReader(fd: client, maxLineBytes: maxLineBytes)
    while let line = try? reader.next() {
      if line.isEmpty { continue }
      let response: Response
      if let request = try? JSONCoding.decoder.decode(Request.self, from: line) {
        response = service.handle(request, origin: origin, caller: caller) { UnixSocket.peerClosed(client) }
      } else {
        response = .failure("can't parse the request")
      }
      guard let text = try? JSONCoding.encode(response),
        (try? UnixSocket.write(client, Data((text + "\n").utf8))) != nil
      else { return }
    }
  }
}
