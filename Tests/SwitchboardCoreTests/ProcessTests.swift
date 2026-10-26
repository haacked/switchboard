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
}
