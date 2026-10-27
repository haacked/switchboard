import Foundation
import SwitchboardCore

/// Serves the line protocol on sbd's Unix socket. Each connection gets its
/// own thread, so a slow request such as `new` does not hold up other clients.
public final class Server {
  let service: Service
  let fd: Int32

  public init(service: Service) throws {
    self.service = service
    self.fd = try UnixSocket.listen(path: service.home.socket)
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
    var reader = UnixSocket.LineReader(fd: client)
    while let line = try? reader.next() {
      if line.isEmpty { continue }
      let response: Response
      if let request = try? JSONCoding.decoder.decode(Request.self, from: line) {
        response = service.handle(request) { UnixSocket.peerClosed(client) }
      } else {
        response = .failure("can't parse the request")
      }
      guard let text = try? JSONCoding.encode(response),
        (try? UnixSocket.write(client, Data((text + "\n").utf8))) != nil
      else { return }
    }
  }
}
