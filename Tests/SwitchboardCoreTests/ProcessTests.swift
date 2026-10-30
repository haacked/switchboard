import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ProcessTests {
  /// Swift Testing runs tests on the cooperative pool, which has one thread
  /// per CPU, and integration tests call runCommand from there in parallel.
  @Test(.timeLimit(.minutes(1))) func runsMoreCommandsAtOnceThanThereAreCPUs() async {
    let count = 2 * ProcessInfo.processInfo.activeProcessorCount
    let statuses = await withTaskGroup(of: Int32.self) { group in
      for _ in 0..<count {
        group.addTask { (try? runCommand("/bin/sleep", ["0.2"]))?.status ?? -1 }
      }
      return await group.reduce(into: [Int32]()) { $0.append($1) }
    }
    #expect(statuses == Array(repeating: 0, count: count))
  }

  @Test(.timeLimit(.minutes(1))) func endsACommandThatOutlastsItsTimeout() throws {
    let start = Date()
    let r = try runCommand("/bin/sleep", ["30"], timeout: 0.3)
    #expect(r.status != 0)
    #expect(Date().timeIntervalSince(start) < 10)
  }

  @Test func leavesACommandThatFinishesInTimeAlone() throws {
    #expect(try runCommand("/bin/echo", ["hi"], timeout: 30).stdout == "hi\n")
  }
}
