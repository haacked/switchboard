import Foundation
import Testing

@testable import SwitchboardCore

/// The expected names come from the folders that claude 2.1.322 created for
/// these paths.
private let world =
  "/private/tmp/claude-501/-Users-haacked-dev-worktrees-switchboard-haacked-shared-projects-permissions/30afca2c-94bc-47dd-93b9-1233d1046abe/scratchpad/worlds/names-13563"
private let worldName =
  "-private-tmp-claude-501--Users-haacked-dev-worktrees-switchboard-haacked-shared-projects-permissions-30afca2c-94bc-47dd-93b9-1233d1046abe-scratchpad-worlds-names-13563"

struct ClaudeFolderTests {
  @Test func replacesEachCharacterThatIsNotAnASCIILetterOrDigitWithADash() {
    #expect(ClaudeFolder.name("/Users/me/dev/my.app_x") == "-Users-me-dev-my-app-x")
    #expect(ClaudeFolder.name("\(world)/café") == "\(worldName)-caf-")
  }

  @Test func replacesEachUTF16UnitOfACharacterOutsideTheBasicPlane() {
    #expect(ClaudeFolder.name("\(world)/rocket🚀x") == "\(worldName)-rocket--x")
  }

  @Test func keepsANameOf200Units() {
    let path = "/" + String(repeating: "a", count: 199)
    #expect(ClaudeFolder.name(path) == "-" + String(repeating: "a", count: 199))
  }

  @Test func cutsALongerNameTo200UnitsAndAddsAHashOfThePath() {
    let long = "\(world)/\(String(repeating: "a", count: 120))/\(String(repeating: "b", count: 60))"
    #expect(ClaudeFolder.name(long) == "\(worldName)-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-65dx9m")
    #expect(
      ClaudeFolder.name("/" + String(repeating: "a", count: 200)) == "-" + String(repeating: "a", count: 199)
        + "-b6ymvl")
    #expect(
      ClaudeFolder.name("/" + String(repeating: "z", count: 205)) == "-" + String(repeating: "z", count: 199)
        + "-tdf4r9")
  }

  @Test func namesTheMemoryFolderUnderTheDefaultAccountWithATilde() {
    #expect(ClaudeFolder.memoryDirectory("/Users/me/dev/my.app") == "~/.claude/projects/-Users-me-dev-my-app/memory")
  }

  @Test func holdsATranscriptInTheFolderNamedAfterTheCwdOrItsRealPath() {
    let transcript = "/Users/me/.claude-max/projects/-private-tmp-work/abc.jsonl"
    #expect(ClaudeFolder.holds(transcript, startedIn: "/private/tmp/work", realPath: nil))
    #expect(ClaudeFolder.holds(transcript, startedIn: "/tmp/work", realPath: "/private/tmp/work"))
    #expect(!ClaudeFolder.holds(transcript, startedIn: "/tmp/work", realPath: "/tmp/work"))
    #expect(!ClaudeFolder.holds(transcript, startedIn: "/private/tmp/work/sub", realPath: nil))
  }

  @Test func findLooksInTheFolderNamedAfterALongOrNonASCIICwdWithoutListingFolders() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let id = UUID().uuidString.lowercased()
    let long = "/Users/me/\(String(repeating: "a", count: 120))/\(String(repeating: "b", count: 90))"
    for cwd in ["/Users/me/rocket🚀x", long] {
      let folder = "\(dir)/projects/\(ClaudeFolder.name(cwd))"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(folder)/\(id).jsonl", contents: nil)

      var listed: [String] = []
      let found = Transcript.find(id, account: dir, cwd: cwd) {
        listed.append($0)
        return []
      }

      #expect(found == "\(folder)/\(id).jsonl")
      #expect(listed.isEmpty)
    }
  }
}
