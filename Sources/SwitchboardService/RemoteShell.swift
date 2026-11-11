import Foundation
import SwitchboardCore

struct RemoteResult {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

/// One child process whose stdin and stdout carry the framing of `RemoteShellProtocol`. The
/// process runs until `close()` or until it ends by itself, also when nothing holds the object.
final class RemoteShell: @unchecked Sendable {
  /// A failure after the request went out. The stream's position is then unknown.
  private struct Broken: Error {
    var reason: String
  }

  private static let closedMidway =
    "the connection closed before the answer arrived, so the command may or may not have run"
  private static let stderrTailLines = 20
  private static let stderrTailBytes = 16 * 1024

  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let onReady: @Sendable (RemoteShellProtocol.Ready) -> Void
  private let onClose: @Sendable (String) -> Void
  private let readyMarker: Data

  /// Guards every `var` below it but `seq` and `inputOpen`.
  private let state = NSCondition()
  private var unread = Data()
  private var handshake: RemoteShellProtocol.Ready?
  private var awaitingAnswer = false
  private var closed = false
  private var stderrTail = Data()
  private let stderrEnded = DispatchSemaphore(value: 0)

  /// Held for a whole command, so one command is in flight at a time. It guards `seq`.
  private let commands = NSLock()
  private var seq = 0

  /// Guards the write descriptor, so `close()` never closes it during a `write`.
  private let input = NSLock()
  private var inputOpen = true

  /// Starts the program and writes the boot script. `onReady` runs when the shell answers the
  /// handshake. `onClose` runs once, with the reason, when the shell ends for any cause. Both
  /// run on the thread that saw the event, which can be the thread of a caller of `run`.
  init(
    executable: String, arguments: [String], environment: [String: String]?,
    onReady: @escaping @Sendable (RemoteShellProtocol.Ready) -> Void,
    onClose: @escaping @Sendable (String) -> Void
  ) throws {
    self.onReady = onReady
    self.onClose = onClose
    let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    readyMarker = Data(RemoteShellProtocol.readyPrefix(token: token).utf8)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let writer = stdinPipe.fileHandleForWriting.fileDescriptor
    // A write to a pipe whose reader ended would otherwise raise SIGPIPE and end sbd.
    _ = fcntl(writer, F_SETNOSIGPIPE, 1)
    // A write must be able to stop at a deadline, so it never blocks.
    _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
    try process.run()

    // Blocking reads run on queues of their own, never on Swift's cooperative pool.
    DispatchQueue(label: "RemoteShell.stdout").async { [self] in
      Self.drain(stdoutPipe.fileHandleForReading.fileDescriptor) { received($0) }
      end(nil)
    }
    DispatchQueue(label: "RemoteShell.stderr").async { [self] in
      Self.drain(stderrPipe.fileHandleForReading.fileDescriptor) { chunk in
        state.withLock { stderrTail = (stderrTail + chunk).suffix(Self.stderrTailBytes) }
      }
      stderrEnded.signal()
    }
    do {
      try send(Data(RemoteShellProtocol.bootScript(token: token).utf8), until: nil)
    } catch let failure as Broken {
      end(failure.reason)
    }
  }

  var pid: Int32 { process.processIdentifier }

  /// What the shell answered in the handshake, or nil before the handshake.
  var ready: RemoteShellProtocol.Ready? { state.withLock { handshake } }

  /// Runs one command. Only one runs at a time. It throws when the shell is closed, when it has
  /// not answered the handshake, and when `RemoteShellProtocol.request` refuses the command.
  /// Those throws send nothing and leave the shell as it was. It also throws when the shell
  /// closes before the whole answer arrives, when the answer breaks the framing, and when
  /// `deadline` seconds pass. Each of those throws also closes the shell.
  func run(_ argv: [String], env: [String: String]?, input: Data?, timeout: Double?, deadline: Double?) throws
    -> RemoteResult
  {
    let limit = deadline.map { Date().addingTimeInterval($0) }
    do {
      return try commands.withLock {
        try state.withLock {
          if closed { throw APIError("the host's shell is closed") }
          if handshake == nil { throw APIError("the host's shell has not answered the handshake") }
        }
        let request = try RemoteShellProtocol.request(
          seq: seq + 1, argv: argv, env: env, input: input, timeout: timeout)
        seq += 1
        state.withLock { awaitingAnswer = true }
        try send(request, until: limit)
        let line = try take(until: limit) { unread in
          if let newline = unread.prefix(RemoteShellProtocol.maxLineBytes + 1).firstIndex(of: UInt8(ascii: "\n")) {
            return newline - unread.startIndex + 1
          }
          if unread.count > RemoteShellProtocol.maxLineBytes { throw Broken(reason: "the host's answer has no header") }
          return nil
        }
        let header: RemoteShellProtocol.Header
        do {
          header = try RemoteShellProtocol.parseHeader(String(decoding: line.dropLast(), as: UTF8.self), seq: seq)
        } catch {
          throw Broken(reason: "\(error)")
        }
        let stdout = try take(until: limit) { $0.count >= header.stdoutBytes ? header.stdoutBytes : nil }
        let stderr = try take(until: limit) { $0.count >= header.stderrBytes ? header.stderrBytes : nil }
        state.withLock { awaitingAnswer = false }
        return RemoteResult(status: header.status, stdout: stdout, stderr: stderr)
      }
    } catch let failure as Broken {
      end(failure.reason)
      throw APIError(failure.reason)
    }
  }

  /// Ends the process. A command in flight throws. The process gets SIGTERM when it still runs
  /// a second after its stdin closed, so `close()` can return before the process ends.
  func close() { end("closed") }

  /// Closes the shell once and reports why. A nil reason means that stdout ended, and the
  /// reason is then what the process last wrote to stderr.
  private func end(_ reason: String?) {
    state.lock()
    if closed {
      state.unlock()
      return
    }
    closed = true
    state.broadcast()
    state.unlock()
    input.withLock {
      inputOpen = false
      try? stdinPipe.fileHandleForWriting.close()
    }
    // The shell removes its temporary folder when it reads the end of its stdin. A shell that
    // waits for a command never reads it.
    DispatchQueue(label: "RemoteShell.terminate").asyncAfter(deadline: .now() + 1) { [process] in
      if process.isRunning { process.terminate() }
    }
    if let reason {
      onClose(reason)
      return
    }
    _ = stderrEnded.wait(timeout: .now() + 1)
    let lines = state.withLock { String(decoding: stderrTail, as: UTF8.self) }
      .split(whereSeparator: \.isNewline).suffix(Self.stderrTailLines)
    onClose(lines.isEmpty ? "the connection closed" : lines.joined(separator: "\n"))
  }

  private static func drain(_ descriptor: Int32, _ body: (Data) -> Void) {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &chunk, chunk.count)
      if count > 0 {
        body(Data(chunk[0..<count]))
      } else if count == 0 || errno != EINTR {
        return
      }
    }
  }

  /// Takes stdout bytes as they arrive. Before the handshake it looks for the ready line and
  /// drops what comes before it. After the handshake, bytes that no command waits for break
  /// the framing.
  private func received(_ chunk: Data) {
    var announce: RemoteShellProtocol.Ready?
    var failure: String?
    state.lock()
    if closed {
      state.unlock()
      return
    }
    unread.append(chunk)
    if handshake == nil {
      if let marker = unread.range(of: readyMarker) {
        let rest = unread[marker.upperBound...]
        if let newline = rest.firstIndex(of: UInt8(ascii: "\n")),
          newline - rest.startIndex <= RemoteShellProtocol.maxLineBytes
        {
          do {
            announce = try RemoteShellProtocol.parseReady(String(decoding: rest[..<newline], as: UTF8.self))
            handshake = announce
            unread = Data(rest[(newline + 1)...])
          } catch {
            failure = "\(error)"
          }
        } else if rest.count > RemoteShellProtocol.maxLineBytes {
          failure = "the host's ready line is too long"
        } else {
          unread = Data(unread[marker.lowerBound...])
        }
      } else {
        unread = Data(unread.suffix(readyMarker.count - 1))
      }
    }
    if handshake != nil, !awaitingAnswer, !unread.isEmpty { failure = "the host sent output that no command asked for" }
    state.broadcast()
    state.unlock()
    if let announce, failure == nil { onReady(announce) }
    if let failure { end(failure) }
  }

  /// Waits until `length` says how many bytes at the front of the unread stdout to take.
  private func take(until limit: Date?, _ length: (Data) throws -> Int?) throws -> Data {
    state.lock()
    defer { state.unlock() }
    while true {
      if let count = try length(unread) {
        let taken = Data(unread.prefix(count))
        unread = Data(unread.dropFirst(count))
        return taken
      }
      if closed { throw Broken(reason: Self.closedMidway) }
      guard let limit else {
        state.wait()
        continue
      }
      if Date() >= limit { throw Broken(reason: "the host did not answer before the deadline") }
      _ = state.wait(until: limit)
    }
  }

  private func send(_ data: Data, until limit: Date?) throws {
    let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
    var sent = 0
    while sent < data.count {
      if let limit, Date() >= limit { throw Broken(reason: "the host did not take the command before the deadline") }
      let (count, code): (Int, Int32) = input.withLock {
        guard inputOpen else { return (-1, EBADF) }
        let count = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + sent, $0.count - sent) }
        return (count, errno)
      }
      if count >= 0 {
        sent += count
      } else if code == EAGAIN {
        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        _ = poll(&waiting, 1, 50)
      } else if code == EBADF || code == EPIPE {
        throw Broken(reason: Self.closedMidway)
      } else if code != EINTR {
        throw Broken(reason: "could not write to the host: \(String(cString: strerror(code)))")
      }
    }
  }
}
