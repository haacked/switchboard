import Foundation
import Testing

@testable import SwitchboardCore

/// `Transcript.eachLineFromEnd` reads the file from the end: first the last 64 KB, then the 128 KB before
/// that, then 256 KB, and so on. Each read starts at a chunk edge, which sits at a fixed distance from the end
/// of the file. Each test sets the file's size to put an edge where it wants one.
@Suite struct TranscriptOffsetTests {
  private static let path = "/box/home/.claude/projects/-box-repo/transcript.jsonl"
  private static let newline = UInt8(ascii: "\n")

  /// A chunk edge, named by the read that starts there.
  enum Edge: Int, CaseIterable, Sendable {
    case chunk64KB = 65_536
    case chunk128KB = 196_608

    /// How many bytes before the end of the file the edge sits.
    var distance: Int { rawValue }
  }

  /// Where a chunk edge falls relative to the lines around it.
  enum Spot: CaseIterable, Sendable {
    case oneByteIntoALine
    case oneByteBeforeItsNewline
    case onANewline
    case atALineStart
    case betweenTwoNewlines

    func holds(in bytes: [UInt8], at edge: Int) -> Bool {
      let newline = TranscriptOffsetTests.newline
      let before = bytes[edge - 1] == newline
      let at = bytes[edge] == newline
      switch self {
      case .oneByteIntoALine: return bytes[edge - 2] == newline && !before && !at
      case .oneByteBeforeItsNewline: return !before && !at && bytes[edge + 1] == newline
      case .onANewline: return !before && at
      case .atALineStart: return before && !at
      case .betweenTwoNewlines: return before && at
      }
    }
  }

  struct Line: Equatable, CustomStringConvertible {
    let offset: UInt64
    let bytes: Data

    var description: String { "\(bytes.count) bytes at \(offset)" }
  }

  /// About 50 KB of short lines, a 150 KB line, and about 400 KB of short lines, ending with a newline.
  /// The 256 KB chunk's edge falls inside the long line.
  private static let body: [UInt8] = {
    var bytes: [UInt8] = []
    appendShortLines(to: &bytes, until: 50_000)
    appendLongLine(to: &bytes, length: 150_000)
    appendShortLines(to: &bytes, until: 600_000)
    return bytes
  }()

  /// Appends lines of 20 to 80 bytes until `bytes` holds at least `count` bytes. Each line starts with its
  /// own offset, so no two lines are equal. Every ninth line is followed by one or two empty lines.
  private static func appendShortLines(to bytes: inout [UInt8], until count: Int) {
    var i = 0
    while bytes.count < count {
      let label = Array("line \(bytes.count) ".utf8)
      let length = 20 + (i * 37) % 61
      bytes += label + (0..<max(0, length - label.count)).map { UInt8(ascii: "a") + UInt8($0 % 26) }
      bytes.append(newline)
      if i % 9 == 0 { bytes += Array(repeating: newline, count: 1 + i % 2) }
      i += 1
    }
  }

  private static func appendLongLine(to bytes: inout [UInt8], length: Int) {
    let label = Array("long \(bytes.count) ".utf8)
    bytes += label + Array(repeating: UInt8(ascii: "x"), count: length - label.count)
    bytes.append(newline)
  }

  private static func tail(_ count: Int) -> [UInt8] { Array(repeating: UInt8(ascii: "t"), count: count) }

  /// The length of a tail with no newline that, appended to `body`, puts `edge` at `spot`.
  private static func tailLength(putting edge: Edge, at spot: Spot) -> Int? {
    (1...1_000).first { spot.holds(in: body, at: body.count + $0 - edge.distance) }
  }

  /// The non-empty lines and their start offsets, found by reading the bytes from the start.
  private static func forwardScan(_ bytes: [UInt8]) -> [Line] {
    var lines: [Line] = []
    var start = 0
    for i in 0...bytes.count where i == bytes.count || bytes[i] == newline {
      if i > start { lines.append(Line(offset: UInt64(start), bytes: Data(bytes[start..<i]))) }
      start = i + 1
    }
    return lines
  }

  /// Every line that `eachLineFromEnd` passes to its body, in the order it passes them.
  private static func walk(
    _ bytes: [UInt8], before end: UInt64? = nil, slices: Bool = false
  ) -> (complete: Bool, lines: [Line]) {
    let machine = OneFileMachine(path: path, bytes: Data(bytes), slices: slices)
    var lines: [Line] = []
    let complete = Transcript.eachLineFromEnd(path, before: end, on: machine) { (line: Data, offset: UInt64) -> Bool in
      lines.append(Line(offset: offset, bytes: Data(line)))
      return false
    }
    return (complete, lines)
  }

  @Test(arguments: Edge.allCases, Spot.allCases)
  func eachLinesOffsetMatchesAForwardScanWhereverAChunkEdgeFalls(_ edge: Edge, _ spot: Spot) throws {
    let tailLength = try #require(Self.tailLength(putting: edge, at: spot))
    let bytes = Self.body + Self.tail(tailLength)
    let expected = Self.forwardScan(bytes)
    try #require(bytes.count > 300_000)
    try #require(bytes.last != Self.newline)
    try #require(expected.contains { $0.bytes.count > Edge.chunk64KB.distance })

    let walk = Self.walk(bytes)

    #expect(walk.complete)
    #expect(walk.lines == Array(expected.reversed()))
  }

  /// No read of the 128 KB chunk holds a newline, so that read passes no line to the body.
  @Test(arguments: [1, 2, 100, 4_000])
  func aLineThatCoversAWholeChunkGetsItsStartOffset(_ tailLength: Int) throws {
    var bytes: [UInt8] = []
    Self.appendShortLines(to: &bytes, until: 60_000)
    let longStart = bytes.count
    Self.appendLongLine(to: &bytes, length: 200_000)
    Self.appendShortLines(to: &bytes, until: bytes.count + 50_000)
    bytes += Self.tail(tailLength)
    try #require(bytes.count > 300_000)
    try #require(longStart < bytes.count - Edge.chunk128KB.distance)
    try #require(bytes.count - Edge.chunk64KB.distance < longStart + 200_000)

    let walk = Self.walk(bytes)

    #expect(walk.complete)
    #expect(walk.lines == Array(Self.forwardScan(bytes).reversed()))
    #expect(walk.lines.first { $0.bytes.count == 200_000 }?.offset == UInt64(longStart))
  }

  @Test(arguments: ["", "\n", "\n\n\n", "a", "a\n", "\na", "a\n\nb\n", "a\nb", "\n\na\n\n"])
  func aFileSmallerThanAChunkGetsTheOffsetsOfAForwardScan(_ text: String) {
    let bytes = Array(text.utf8)

    let walk = Self.walk(bytes)

    #expect(walk.complete)
    #expect(walk.lines == Array(Self.forwardScan(bytes).reversed()))
  }

  @Test func aTranscriptThatEndsWithEmptyLinesGetsTheOffsetsOfAForwardScan() {
    let bytes = Self.body + Array("last\n\n\n".utf8)

    let walk = Self.walk(bytes)

    #expect(walk.complete)
    #expect(walk.lines == Array(Self.forwardScan(bytes).reversed()))
  }

  /// A slice of `Data` keeps the indices of the data it came from, so its first index is not 0.
  @Test(arguments: Spot.allCases)
  func aMachineThatReadsSlicesGetsTheOffsetsOfAForwardScan(_ spot: Spot) throws {
    let tailLength = try #require(Self.tailLength(putting: .chunk64KB, at: spot))
    let bytes = Self.body + Self.tail(tailLength)

    let walk = Self.walk(bytes, slices: true)

    #expect(walk.complete)
    #expect(walk.lines == Array(Self.forwardScan(bytes).reversed()))
  }

  /// `SlashCommands` walks only the bytes before a size it measured. The edges then sit at fixed distances
  /// before that size.
  @Test(arguments: Spot.allCases)
  func withAnEndEachLinesOffsetMatchesAForwardScanOfTheBytesBeforeIt(_ spot: Spot) throws {
    let end = try #require(
      (300_000..<301_000).first { spot.holds(in: Self.body, at: $0 - Edge.chunk64KB.distance) })

    let walk = Self.walk(Self.body, before: UInt64(end))

    #expect(walk.complete)
    #expect(walk.lines == Array(Self.forwardScan(Array(Self.body[..<end])).reversed()))
  }
}

/// A machine that holds one file in memory. With `slices`, a read returns a slice of the file's data instead of
/// a copy.
private struct OneFileMachine: Machine {
  let path: String
  let bytes: Data
  let slices: Bool

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    CommandResult(status: 0, stdout: "", stderr: "")
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    guard path == self.path else { return nil }
    let rest = bytes.dropFirst(Int(min(offset, UInt64(bytes.count))))
    let part = count.map { rest.prefix($0) } ?? rest
    return slices ? part : Data(part)
  }

  func size(_ path: String) -> UInt64? { path == self.path ? UInt64(bytes.count) : nil }
  func exists(_ path: String) -> Bool { path == self.path }
  func isFolder(_ path: String) -> Bool { self.path.hasPrefix(path + "/") }
  func modified(_ path: String) -> Date? { nil }
  func list(_ folder: String) -> [String] { [] }
  func createFolder(_ path: String) throws {}
  func signal(_ pid: Int, _ signal: Int32) {}
}
