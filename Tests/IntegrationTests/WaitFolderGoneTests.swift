import Foundation
import SwitchboardCore
import Testing

/// A wait whose `resume` can't start the session, because its folder is gone or because the removal job holds it.
@Suite(.blocking(timeLimit: .seconds(120))) struct WaitFolderGoneTests {
  static let hourMs: Int64 = 3600 * 1000

  /// A session with a date wait that resumes it in an hour, and whose claude has exited, so the resume starts claude.
  func stoppedSessionWithADateWait(_ sbd: Instance) throws -> (SessionSummary, Wait) {
    let s = try sbd.idleSession()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try stop(sbd, s)
    return (s, try #require(try sbd.get(s.id).waits.first))
  }

  func stop(_ sbd: Instance, _ s: SessionSummary) throws {
    try sbd.passIdleStop(s.id)
    try sbd.waitFor(s.id, "claude to exit", timeout: 30) { $0.claudePid == nil }
  }

  func moveFolderAway(_ s: SessionSummary) throws {
    try FileManager.default.moveItem(atPath: s.cwd, toPath: s.cwd + ".away")
  }

  func logLines(_ sbd: Instance, naming wait: Wait) -> [Substring] {
    let log = (try? String(contentsOfFile: sbd.home.log, encoding: .utf8)) ?? ""
    return log.split(separator: "\n").filter { $0.contains(wait.id) }
  }

  /// The folder does not come back, so a retry on every tick would only log the same error again.
  @Test func aDueResumeWaitOnASessionWhoseFolderIsGoneClosesOnceAndLogsOnce() throws {
    let sbd = try Instance()
    let (s, wait) = try stoppedSessionWithADateWait(sbd)
    try moveFolderAway(s)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * WaitFolderGoneTests.hourMs)
    try sbd.tickThrice()

    #expect(try sbd.get(s.id).waits.isEmpty)
    let resolved = try sbd.events(s.id, after: mark).filter { $0.kind == "wait-resolved" }
    #expect(resolved.count == 1)
    #expect(resolved.first?.data["outcome"]?.string == "the time came")
    #expect(resolved.first?.data["error"]?.string?.contains("is gone") == true, "\(resolved)")
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "sent" }.isEmpty)
    let lines = logLines(sbd, naming: wait)
    #expect(lines.count == 1, "\(lines)")
  }

  @Test func resolvingAResumeWaitOnASessionWhoseFolderIsGoneClosesIt() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    try sbd.sb("wait", s.id, "--kind", "merge", "--target", "1190")
    try stop(sbd, s)
    try moveFolderAway(s)
    let mark = try sbd.lastEventId(s.id)

    try sbd.sb("wait", s.id, "--resolve", "#1190 merged")

    #expect(try sbd.get(s.id).waits.isEmpty)
    let resolved = try sbd.events(s.id, after: mark).filter { $0.kind == "wait-resolved" }
    #expect(resolved.count == 1)
    #expect(resolved.first?.data["error"]?.string?.contains("is gone") == true, "\(resolved)")
    try sbd.tickThrice()
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)
  }

  /// A folder above the session's folder denies search, so sbd can't tell whether the folder is gone. The wait stays
  /// open and resumes the session once the folder can be read again.
  @Test func aDueResumeWaitOnASessionWhoseFolderCantBeReadStaysOpenAndResumesItLater() throws {
    let sbd = try Instance()
    let locked = "\(sbd.home.path)/locked"
    let folder = "\(locked)/inner"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
    let s = try sbd.client.call(
      "new", ["path": .string(folder), "name": "inner", "prompt": "hello"], as: SessionSummary.self)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h")
    try stop(sbd, s)
    let wait = try #require(try sbd.get(s.id).waits.first)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * WaitFolderGoneTests.hourMs)
    try sbd.tickThrice()

    #expect(try sbd.get(s.id).waits.map(\.id) == [wait.id])
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "wait-resolved" }.isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
    try sbd.advanceClock(1)

    let resumed = try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    #expect(resumed.waits.isEmpty)
  }

  /// The removal job's hold ends with Undo, so the wait stays open and the tick after the Undo resumes the session.
  @Test func aDueResumeWaitOnASessionTheRemovalJobHoldsStaysOpenAndResumesItAfterUndo() throws {
    let sbd = try longUndoInstance()
    let (s, wait) = try stoppedSessionWithADateWait(sbd)
    try sbd.holdForRemoval(s.id)
    let mark = try sbd.lastEventId(s.id)

    try sbd.advanceClock(2 * WaitFolderGoneTests.hourMs)
    try sbd.tickThrice()

    #expect(try sbd.get(s.id).waits.map(\.id) == [wait.id])
    #expect(try sbd.events(s.id, after: mark).filter { $0.kind == "wait-resolved" }.isEmpty)
    #expect(try sbd.launchEvents(s.id, after: mark).isEmpty)

    #expect(cancelled(try sbd.cancelRemoval([s.id])) == [s.id])
    try sbd.advanceClock(1)

    let resumed = try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    #expect(resumed.waits.isEmpty)
    #expect(try sbd.launchEvents(s.id, after: mark).count == 1)
  }
}
