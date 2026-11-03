import Foundation
import SwitchboardCore

/// The OAuth usage endpoint on 127.0.0.1 for one test. It answers every
/// request with the reply that the test set last, or with the reply set for
/// the request's token. It records the headers that sbd sends.
final class FakeUsage {
  struct Request {
    var method: String
    var path: String
    var authorization: String?
    var beta: String?
  }

  struct Reply {
    var status: Int
    var body: String
  }

  /// The responses that Tests/SwitchboardCoreTests/Fixtures/usage recorded.
  static let fixtures = Instance.root.appendingPathComponent("Tests/SwitchboardCoreTests/Fixtures/usage").path

  static func recorded(_ name: String) throws -> String {
    try String(contentsOfFile: "\(fixtures)/\(name).json", encoding: .utf8)
  }

  private let fd: Int32
  let port: Int
  private let lock = NSLock()
  private var log: [Request] = []
  private var fallback: Reply
  private var byToken: [String: Reply] = [:]

  /// It answers with the recorded with-session.json until a test sets another reply.
  init() throws {
    fallback = Reply(status: 200, body: try FakeUsage.recorded("with-session"))
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
        bind(listener, p, len) == 0 && listen(listener, 16) == 0 && getsockname(listener, p, &len) == 0
      }
    }
    guard bound else {
      close(listener)
      throw TestError(description: "can't listen on 127.0.0.1")
    }
    fd = listener
    port = Int(UInt16(bigEndian: addr.sin_port))
    // The thread holds the fake weakly, so deinit closes the socket, which
    // ends the thread's accept.
    Thread.detachNewThread { [weak self] in
      while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        self?.handle(client)
        close(client)
      }
    }
  }

  deinit { close(fd) }

  /// The URL for config.json's `usage.url`, at the endpoint's real path.
  var url: String { "http://127.0.0.1:\(port)/api/oauth/usage" }

  var requests: [Request] { lock.withLock { log } }

  /// Answers every later request with this status and body.
  func reply(_ body: String, status: Int = 200) {
    lock.withLock { fallback = Reply(status: status, body: body) }
  }

  /// Answers every later request that sends `Bearer <token>` with this
  /// status and body.
  func reply(to token: String, _ body: String, status: Int = 200) {
    lock.withLock { byToken["Bearer \(token)"] = Reply(status: status, body: body) }
  }

  // MARK: HTTP

  private func handle(_ client: Int32) {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var headers: [String: String] = [:]
    var requestLine = ""
    var length = 0
    while true {
      let n = recv(client, &buffer, buffer.count, 0)
      if n <= 0 { return }
      data.append(buffer, count: n)
      if headerEnd == nil, let range = data.range(of: separator) {
        headerEnd = range
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        requestLine = lines.first ?? ""
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        length = Int(headers["content-length"] ?? "0") ?? 0
      }
      if let end = headerEnd, data.count - end.upperBound >= length { break }
    }
    let parts = requestLine.split(separator: " ").map(String.init)
    let request = Request(
      method: parts.first ?? "", path: parts.count > 1 ? parts[1] : "", authorization: headers["authorization"],
      beta: headers["anthropic-beta"])
    let reply = lock.withLock { () -> Reply in
      log.append(request)
      return request.authorization.flatMap { byToken[$0] } ?? fallback
    }
    var head = "HTTP/1.1 \(reply.status) Fake\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
    try? UnixSocket.write(client, Data((head + "\r\n" + reply.body).utf8))
  }
}
