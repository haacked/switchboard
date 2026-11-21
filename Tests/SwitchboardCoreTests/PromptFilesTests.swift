import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct PromptFilesTests {
  private func temp() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A copy of the real prompt files, which a test then breaks.
  private func copyOfPrompts() throws -> URL {
    let dir = try temp()
    let source = Prompts.folder(environment: [:])
    for file in try FileManager.default.contentsOfDirectory(atPath: source.path) {
      try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: dir.appendingPathComponent(file))
    }
    return dir
  }

  @Test func everyPromptFileLoadsAndFillsEveryPlaceholder() throws {
    let library = try PromptLibrary(directory: Prompts.folder(environment: [:]))
    for prompt in Prompt.allCases {
      let text = try #require(library.texts[prompt])
      #expect(!text.isEmpty, "\(prompt)")
      #expect(!text.contains("{{"), "\(prompt) left a placeholder unfilled")
      #expect(!text.hasSuffix("\n"), "\(prompt)")
    }
  }

  @Test func theFolderHoldsExactlyThePromptsInTheEnum() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: Prompts.folder(environment: [:]).path).sorted()
    #expect(files == Prompt.allCases.map(\.fileName).sorted())
  }

  @Test func theAccessorsReadTheFiles() {
    #expect(Manager.guide == Prompts.text(.managerGuide))
    #expect(Manager.guide.contains("sb schedule \(Manager.operatorName) --every 30m"))
    #expect(TriageSummarizer.system.contains("under \(Triage.titleLength) characters"))
  }

  @Test func aMissingFileIsAnErrorThatNamesIt() throws {
    let dir = try copyOfPrompts()
    try FileManager.default.removeItem(at: dir.appendingPathComponent("manager-guide.md"))
    #expect(throws: PromptError.self) { try PromptLibrary(directory: dir) }
    do { _ = try PromptLibrary(directory: dir) } catch {
      #expect("\(error)".contains("manager-guide.md"), "\(error)")
    }
  }

  @Test func aPlaceholderWithNoValueIsAnError() throws {
    let dir = try copyOfPrompts()
    let file = dir.appendingPathComponent("session-namer.md")
    try (try String(contentsOf: file, encoding: .utf8) + "{{mystery}}\n").write(
      to: file, atomically: true, encoding: .utf8)
    do {
      _ = try PromptLibrary(directory: dir)
      Issue.record("loaded")
    } catch {
      #expect("\(error)".contains("{{mystery}}"), "\(error)")
    }
  }

  @Test func aValueThatNoFileUsesIsAnError() throws {
    let dir = try copyOfPrompts()
    let file = dir.appendingPathComponent("plan-updates.md")
    let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
      of: "{{planUpdatesCellLength}}", with: "300")
    try text.write(to: file, atomically: true, encoding: .utf8)
    do {
      _ = try PromptLibrary(directory: dir)
      Issue.record("loaded")
    } catch {
      #expect("\(error)".contains("{{planUpdatesCellLength}}"), "\(error)")
    }
  }

  @Test func aStrayDoubleBraceIsAnError() throws {
    let dir = try copyOfPrompts()
    let file = dir.appendingPathComponent("quick-ask.md")
    try (try String(contentsOf: file, encoding: .utf8) + "{{ not a name }}\n").write(
      to: file, atomically: true, encoding: .utf8)
    #expect(throws: PromptError.self) { try PromptLibrary(directory: dir) }
  }

  @Test func aValueThatContainsBracesIsNotFilledAgain() throws {
    let text = try PromptTemplate.fill("a {{x}} b {{y}}", with: ["x": "{{y}}", "y": "Y"], file: "f")
    #expect(text == "a {{y}} b Y")
  }

  @Test func theFolderIsFoundInTheInstalledLayout() throws {
    let app = try temp().appendingPathComponent("Fake.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: app.appendingPathComponent("Contents/Resources/Prompts"), withIntermediateDirectories: true)
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(AppBundle.identifier)</string></dict></plist>
      """
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let sbd = macOS.appendingPathComponent("sbd")
    try Data().write(to: sbd)
    let found = Prompts.folder(executable: sbd, environment: [:])
    #expect(
      found.resolvingSymlinksInPath().path
        == app.appendingPathComponent("Contents/Resources/Prompts").resolvingSymlinksInPath().path)
    #expect(Prompts.folder(executable: sbd, environment: ["SB_PROMPTS_DIR": "/somewhere"]).path == "/somewhere")
    #expect(
      Prompts.folder(executable: sbd, environment: ["SB_PROMPTS_DIR": ""]).resolvingSymlinksInPath().path
        == app.appendingPathComponent("Contents/Resources/Prompts").resolvingSymlinksInPath().path)
  }

  @Test func theEnvironmentOverridesTheFolder() {
    #expect(Prompts.folder(environment: ["SB_PROMPTS_DIR": "/somewhere"]).path == "/somewhere")
  }
}
