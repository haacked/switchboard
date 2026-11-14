import Foundation
import SwitchboardCore
import Testing

private func checkTitle(_ title: String) throws -> CommandResult {
  let script = Instance.root.appendingPathComponent("bin/check-pr-title").path
  return try runCommand("/bin/bash", [script, title], timeout: 30)
}

@Suite(.blocking(timeLimit: .seconds(60))) struct PRTitleTests {
  @Test(arguments: [
    "feat: Print the changes since the last update",
    "fix(sbd): Keep the session ready",
    "feat!: Rename the sb list command",
    "refactor(core)!: Move ago into Core",
    "perf: Read the log once",
    "docs: Describe bin/changelog",
    "test: Cover an empty range",
    "build: Give each test shard its own build slot",
    "ci: Check PR titles",
    "chore: Bump the tools",
  ])
  func aConventionalTitlePasses(_ title: String) throws {
    let r = try checkTitle(title)

    #expect(r.status == 0, "\(r.stderr)")
  }

  @Test(arguments: [
    "Add an Issues view",
    "feat: lowercase summary",
    "feat:No space",
    "feat:  Two spaces",
    "feature: Unknown type",
    "Feat: Capital type",
    "feat(): Empty scope",
    "feat(a)(b): Two scopes",
    " feat: Leading space",
    "feat: ",
    "",
  ])
  func anotherTitleFailsAndExplainsTheForm(_ title: String) throws {
    let r = try checkTitle(title)

    #expect(r.status == 1)
    #expect(r.stderr.contains("type(scope): Summary"), "\(r.stderr)")
  }

  @Test func aTitleIsNeverRunAsCode() throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pr-title-\(UUID().uuidString)").path

    let r = try checkTitle("feat: $(touch \(marker)) `touch \(marker)`")

    #expect(r.status == 1)
    #expect(!FileManager.default.fileExists(atPath: marker))
  }
}
