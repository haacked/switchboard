import Foundation
import SwitchboardCore

/// The text that sbd and a host's `/bin/sh` exchange over one connection. Every function is pure.
enum RemoteShellProtocol {
  static let maxLineBytes = 256

  /// The `stat` that the host has. Both formats print `<bytes> <seconds>.<nanoseconds>`.
  enum StatFormat: String, Sendable {
    case gnu, bsd

    var arguments: [String] {
      switch self {
      case .gnu: return ["-c", "%s %.9Y"]
      case .bsd: return ["-f", "%z %Fm"]
      }
    }
  }

  struct Ready: Sendable {
    var stat: StatFormat
  }

  struct Header {
    var status: Int32
    var stdoutBytes: Int
    var stderrBytes: Int
  }

  /// The text that a host's shell must print before a ready line counts as the handshake.
  static func readyPrefix(token: String) -> String { "SB1 ready \(token) " }

  /// The functions that the host's shell needs, then the ready line. `token` is 32 hex digits.
  ///
  /// `sb_run` removes the files `$sb_d/i`, `$sb_d/o`, and `$sb_d/e` after it prints the answer, so
  /// each command opens files that no earlier command had open. A process that outlives its
  /// command keeps the removed files, and no later command reads what it writes or gives it
  /// input. The shell exits when it can't remove them.
  ///
  /// A timeout is a `sleep` that holds the write end of the FIFO `$sb_d/f` and a subshell that
  /// reads the FIFO. The subshell reads the end of the FIFO when the `sleep` ends, and then it
  /// ends the program. `sb_run` ends the subshell first and the `sleep` second when the program
  /// ends in time. A `sleep` that the subshell ran itself would run on for the whole timeout
  /// after every command, because ending a subshell does not end its child. The `sleep` sends
  /// stderr to /dev/null before it opens the FIFO, because bash reports an open that a signal
  /// interrupts.
  static func bootScript(token: String) -> String {
    #"""
    sb_d=$(mktemp -d "${TMPDIR:-/tmp}/sb-sh.XXXXXX") || exit 97
    trap 'rm -rf "$sb_d"' EXIT
    mkfifo "$sb_d/f" || exit 97
    if sb_p=$(stat -c '%s %.9Y' -- / 2>/dev/null); then sb_s=gnu
    elif sb_p=$(stat -f '%z %Fm' -- / 2>/dev/null); then sb_s=bsd
    else sb_s=none; sb_p='0 0'; fi
    [ "$(printf aGk= | base64 -d 2>/dev/null)" = hi ] || sb_s=none
    sb_emit() {
      sb_o=$(wc -c <"$sb_d/o"); sb_e=$(wc -c <"$sb_d/e"); sb_o=$((sb_o)); sb_e=$((sb_e))
      printf 'SB1 %s %s %s %s\n' "$1" "$2" "$sb_o" "$sb_e"
      [ "$sb_o" -gt 0 ] && head -c "$sb_o" "$sb_d/o"
      [ "$sb_e" -gt 0 ] && head -c "$sb_e" "$sb_d/e"
      :
    }
    sb_run() {
      sb_n=$1; sb_t=$2; shift 2
      ( exec "$@" ) <"$sb_d/i" >"$sb_d/o" 2>"$sb_d/e" & sb_c=$!
      sb_w=
      if [ -n "$sb_t" ]; then
        sleep "$sb_t" 2>/dev/null >"$sb_d/f" & sb_k=$!
        ( read sb_z <"$sb_d/f"; kill -TERM "$sb_c"; sleep 2; kill -KILL "$sb_c" ) >/dev/null 2>&1 & sb_w=$!
      fi
      wait "$sb_c" 2>/dev/null; sb_x=$?
      if [ -n "$sb_w" ]; then
        kill "$sb_w" 2>/dev/null; wait "$sb_w" 2>/dev/null
        kill "$sb_k" 2>/dev/null; wait "$sb_k" 2>/dev/null
      fi
      sb_emit "$sb_n" "$sb_x"
      rm -f "$sb_d/i" "$sb_d/o" "$sb_d/e" || exit 97
    }

    """# + "printf 'SB1 ready %s %s %s\\n' \(quote(token)) \"$sb_s\" \"$sb_p\"\n"
  }

  /// The word in single quotes, for the host's shell. It is correct for every byte but NUL.
  /// `shellQuote` leaves a `'` bare when a combining character follows it, because it searches
  /// by character and not by byte.
  static func quote(_ word: String) -> String {
    var quoted = String.UnicodeScalarView()
    quoted.append("'")
    for scalar in word.unicodeScalars {
      if scalar == "'" { quoted.append(contentsOf: "'\\''".unicodeScalars) } else { quoted.append(scalar) }
    }
    quoted.append("'")
    return String(quoted)
  }

  private static func isEnvironmentName(_ name: String) -> Bool {
    func isLetter(_ b: UInt8) -> Bool {
      (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
        || b == UInt8(ascii: "_")
    }
    guard let first = name.utf8.first, isLetter(first) else { return false }
    return name.utf8.allSatisfy { isLetter($0) || isDigit($0) }
  }

  private static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }

  /// The block that runs one command. It refuses an empty program, a NUL in any word, an
  /// environment name that is not an identifier, and a timeout that is not finite and above 0.
  /// The shell would read each of those as something else.
  static func request(seq: Int, argv: [String], env: [String: String]?, input: Data?, timeout: Double?) throws
    -> Data
  {
    guard let executable = argv.first, !executable.isEmpty else { throw APIError("a command needs a program to run") }
    var words = argv
    if let env {
      if let name = env.keys.first(where: { !isEnvironmentName($0) }) {
        throw APIError("\(String(reflecting: name)) can't be the name of an environment variable")
      }
      words =
        ["/usr/bin/env", "-i"] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        + ["/bin/sh", "-c", #"exec "$0" "$@""#] + argv
    }
    guard !words.contains(where: { $0.utf8.contains(0) }) else {
      throw APIError("a command for a host can't hold a NUL byte")
    }
    var seconds = ""
    if let timeout {
      guard timeout.isFinite, timeout > 0 else { throw APIError("a timeout must be a number of seconds above 0") }
      seconds = String(format: "%.3f", max(1, (timeout * 1000).rounded()) / 1000)
    }
    let run = "sb_run \(seq) '\(seconds)' " + words.map(quote).joined(separator: " ") + "\n"
    guard let input, !input.isEmpty else { return Data((": >\"$sb_d/i\"\n" + run).utf8) }
    let base64 = input.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
    return Data(
      ("if base64 -d >\"$sb_d/i\" <<'_SB_'\n\(base64)\n_SB_\nthen \(run)else printf 'SB1 %s x 0 0\\n' \(seq)\nfi\n")
        .utf8)
  }

  private static func wholeNumber(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.utf8.allSatisfy(isDigit) else { return nil }
    return Int(text)
  }

  /// The answer's first line, without its newline. It throws for anything but
  /// `SB1 <seq> <status> <stdoutBytes> <stderrBytes>` with the sequence number that was sent.
  static func parseHeader(_ line: String, seq: Int) throws -> Header {
    let broken = APIError("the host's answer does not start with the header of command \(seq)")
    guard line.utf8.count <= maxLineBytes else { throw broken }
    let fields = line.utf8.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false).map { Substring($0) }
    guard fields.count == 5, fields[0].utf8.elementsEqual("SB1".utf8),
      fields[1].utf8.elementsEqual(String(seq).utf8)
    else { throw broken }
    if fields[2].utf8.elementsEqual("x".utf8) { throw APIError("the host could not decode the command's input") }
    guard let status = wholeNumber(fields[2]).flatMap({ Int32(exactly: $0) }), let stdoutBytes = wholeNumber(fields[3]),
      let stderrBytes = wholeNumber(fields[4])
    else { throw broken }
    return Header(status: status, stdoutBytes: stdoutBytes, stderrBytes: stderrBytes)
  }

  /// What follows `SB1 ready <token> ` on the ready line: `<gnu|bsd|none> <size> <mtime>`.
  static func parseReady(_ text: String) throws -> Ready {
    let fields = text.utf8.split(separator: UInt8(ascii: " "), maxSplits: 1, omittingEmptySubsequences: false).map {
      String(Substring($0))
    }
    if fields.first == "none" { throw APIError("the host has no stat or base64 that Switchboard can use") }
    guard fields.count == 2, let stat = StatFormat(rawValue: fields[0]), parseStat(fields[1]) != nil else {
      throw APIError("the host's stat printed text that Switchboard can't read: \(String(reflecting: text))")
    }
    return Ready(stat: stat)
  }

  /// `<bytes> <seconds>[.<fraction>]` with an optional newline at the end, as both stat formats print.
  static func parseStat(_ text: String) -> (size: UInt64, modified: Date)? {
    var bytes = Substring(text).utf8
    if bytes.last == UInt8(ascii: "\n") { bytes = bytes.dropLast() }
    let fields = bytes.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
    guard fields.count == 2, !fields[0].isEmpty, fields[0].allSatisfy(isDigit),
      let size = UInt64(Substring(fields[0]))
    else { return nil }
    let time = fields[1].split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    guard time.count == 1 || time.count == 2, time.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }),
      let seconds = Double(Substring(fields[1])), seconds.isFinite
    else { return nil }
    return (size, Date(timeIntervalSince1970: seconds))
  }

  // The file scripts. Each is the argv of one command, and the path is an argv word.

  private static func script(_ text: String, _ arguments: [String]) -> [String] {
    ["/bin/sh", "-c", text, "sb"] + arguments
  }

  private static func statArguments(_ format: StatFormat) -> String {
    format.arguments.map(quote).joined(separator: " ")
  }

  /// It refuses anything but a regular file before it opens it, so a FIFO can't block the shell.
  /// `head -c 0` fails on macOS, so a count of 0 has its own branch.
  static func read(_ path: String, from offset: UInt64, count: Int?) -> [String] {
    let start = offset >= UInt64(Int64.max) ? Int64.max : Int64(offset) + 1
    return script(
      #"[ -f "$1" ] || exit 1; exec <"$1" || exit 1; if [ "$3" = all ]; then exec tail -c "+$2"; "#
        + #"elif [ "$3" -eq 0 ]; then exit 0; else tail -c "+$2" | head -c "$3"; fi"#,
      [path, String(start), count.map { String($0) } ?? "all"])
  }

  static func size(_ path: String, _ format: StatFormat) -> [String] {
    script(#"[ -f "$1" ] && [ -r "$1" ] || exit 1; exec stat -L \#(statArguments(format)) -- "$1""#, [path])
  }

  static func exists(_ path: String) -> [String] { script(#"[ -e "$1" ]"#, [path]) }

  static func isFolder(_ path: String) -> [String] { script(#"[ -d "$1" ]"#, [path]) }

  static func modified(_ path: String, _ format: StatFormat) -> [String] {
    script(#"exec stat \#(statArguments(format)) -- "$1""#, [path])
  }

  /// Prints each name in the folder with a NUL after it.
  static func list(_ folder: String) -> [String] {
    script(
      #"cd -- "$1" 2>/dev/null || exit 1; for f in * .*; do case $f in .|..) continue;; esac; "#
        + #"[ -e "$f" ] || [ -L "$f" ] || continue; printf '%s\0' "$f"; done"#,
      [folder])
  }

  static func createFolder(_ path: String) -> [String] { script(#"exec mkdir -p -- "$1""#, [path]) }

  static func signal(name: String, pid: Int) -> [String] { script(#"kill -s "$1" "$2""#, [name, String(pid)]) }
}
