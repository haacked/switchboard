import Foundation
import Testing

@testable import SwitchboardCore

/// A listening socket in a new folder under /tmp, because a Unix socket path can't exceed 103 bytes.
private func withListener(_ body: (_ listener: Int32, _ path: String) throws -> Void) throws {
  var template = Array("/tmp/sbt.XXXXXX".utf8CString)
  guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
  let folder = String(cString: dir)
  defer { try? FileManager.default.removeItem(atPath: folder) }
  let path = "\(folder)/sbd.sock"
  let listener = try UnixSocket.listen(path: path)
  defer { close(listener) }
  try body(listener, path)
}

/// Accepts one connection, as `Server` does. It throws when none arrives within the time, so a client that failed
/// to connect fails the test instead of blocking it.
private func acceptOne(_ listener: Int32, within seconds: Int32 = 10) throws -> Int32 {
  var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
  guard poll(&waiting, 1, seconds * 1000) == 1 else { throw APIError("no client connected") }
  let fd = accept(listener, nil, nil)
  guard fd >= 0 else { throw APIError("accept: \(UnixSocket.errnoText())") }
  return fd
}

@Suite struct UnixSocketTests {
  /// connect returns once the kernel queues the connection, so one thread can connect and then accept.
  @Test(.timeLimit(.minutes(1))) func peerPidOfAConnectionFromThisProcessIsThisProcess() throws {
    try withListener { listener, path in
      let client = try UnixSocket.connect(path: path, timeout: 5)
      defer { close(client) }
      let server = try acceptOne(listener)
      defer { close(server) }

      #expect(UnixSocket.peerPid(server) == Int(getpid()))
    }
  }

  /// The peer is another process, so the pid tells the client's end from the server's. perl keeps the socket in
  /// `$s`, because it closes a socket that no variable holds.
  @Test(.timeLimit(.minutes(1))) func peerPidOfAConnectionFromAChildIsTheChild() throws {
    try withListener { listener, path in
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
      child.arguments = [
        "-MIO::Socket::UNIX", "-e", "my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die \"connect: $!\"; sleep 30",
        path,
      ]
      child.standardInput = FileHandle.nullDevice
      child.standardOutput = FileHandle.nullDevice
      try child.run()
      defer {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
      }
      let server = try acceptOne(listener)
      defer { close(server) }

      #expect(UnixSocket.peerPid(server) == Int(child.processIdentifier))
    }
  }

  @Test func peerPidOfAPipeIsNil() throws {
    var fds: [Int32] = [0, 0]
    try #require(pipe(&fds) == 0)
    defer { fds.forEach { close($0) } }

    #expect(UnixSocket.peerPid(fds[0]) == nil)
  }

  @Test func peerPidOfAClosedDescriptorIsNil() {
    #expect(UnixSocket.peerPid(-1) == nil)
  }
}
