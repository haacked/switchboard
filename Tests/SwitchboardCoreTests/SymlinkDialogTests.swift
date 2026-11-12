import Foundation
import Testing

@testable import SwitchboardCore

/// The cwd of the session whose dialogs Claude Code 2.1.322 drew in the
/// `*-symlink` screens. Its `link` folder is a symbolic link to `../real`.
let symlinkCwd =
  "/private/tmp/claude-501/-Users-someone-dev-worktrees-switchboard-someone-write-create-card/00000000-0000-0000-0000-000000000000/scratchpad/cap2/work"

/// The cwd of write-memory.txt, a reproduction of the Write that lost its card
/// in session smnb9i. Its target folder sits under a symbolic link, because
/// `~/.claude-automation/projects` links to `~/.claude/projects`.
let memoryCwd = "/Users/someone/dev/worktrees/switchboard/someone/org-filter"
let memoryFile =
  "/Users/someone/.claude-automation/projects/-Users-someone-dev-someone-switchboard/memory/org-filter-status-x.md"

/// The content of write-memory.txt's Write.
let memoryContent = """
  ---
  name: org-filter-status
  description: App-wide GitHub org filter merged 2026-11-11 (PR #223); open follow-ups listed
  metadata:
    type: project
  ---

  The app-wide GitHub org filter merged on 2026-11-11 as PR #223. It shares board-repo-grouping's `SessionSummary.repository` derivation (origin remote of the main checkout) and adds `repositoryRead`, so the app never hides a session whose org sbd hasn't read.

  **Why:** The user asked to narrow every session view to one org or a few. The filter only hides sessions, and they keep running.

  **How to apply:** New views that list sessions should read `BoardModel.sessions`, `followups`, or `board`, which the filter already applies to. A lookup of one session by id should read `allSessions` or `allBoard`. A destructive action should check `removableIDs` (see `DoneRemoval.swift`). Open items left for the user:
  - At 900 pt the toolbar overflows into its chevron.
  - `sb ls --org` also lists the Manager, group chats, and unread sessions.
  - A failed git read counts as Local.
  - Merge All and Send All have no filter tests.
  - VoiceOver labels on the popover rows.

  Related: [[decision-wizard-status]], [[group-account-status]].

  """

func memoryCard(_ path: String = memoryFile, _ content: String = memoryContent, cwd: String? = memoryCwd) -> Card {
  writeCard(path, content, cwd: cwd)
}

let linkedNotes = "\(symlinkCwd)/link/notes.txt"

/// Dialogs for a file that a symbolic link puts outside the cwd. Claude Code
/// 2.1.322 adds a warning below the path, which can wrap.
@Suite struct SymlinkDialogShows {
  @Test(arguments: [
    (memoryCard(), "write-memory"),
    (writeCard("\(symlinkCwd)/link/new.txt", "one\ntwo", cwd: symlinkCwd), "write-symlink"),
    (writeCard(linkedNotes, "alpha\nBETA\ngamma\ndelta", cwd: symlinkCwd), "write-overwrite-symlink"),
    (editCard(linkedNotes, cwd: symlinkCwd), "edit-symlink"),
    (readCard(linkedNotes, cwd: symlinkCwd), "read-symlink"),
    (readCard(linkedNotes, cwd: nil), "read-symlink"),
  ])
  func aDialogWithTheSymlinkWarningShowsItsCard(_ card: Card, _ fixture: String) throws {
    #expect(ClaudeScreen.shows(card, try dialog(fixture)))
    #expect(ClaudeScreen.mayShow(card, try dialog(fixture)))
  }

  @Test(arguments: [
    "\(memoryCwd)/../../../../../.claude-automation/projects/-Users-someone-dev-someone-switchboard/memory/other.md",
    "/Users/someone/.claude/projects/-Users-someone-dev-someone-switchboard/memory/org-filter-status-x.md",
    "/Users/someone/.claude-automation/projects/-Users-someone-dev-someone-switchboard/org-filter-status-x.md",
  ])
  func aWriteOfAnotherFileIsNotShown(_ path: String) throws {
    #expect(!ClaudeScreen.shows(memoryCard(path), try dialog("write-memory")))
  }

  @Test(arguments: [
    memoryContent.replacingOccurrences(of: "VoiceOver", with: "Voice Over labels"),
    memoryContent.replacingOccurrences(of: "  type: project\n", with: ""),
    memoryContent + "extra\n",
  ])
  func aWriteOfOtherContentIsNotShown(_ content: String) throws {
    #expect(!ClaudeScreen.shows(memoryCard(memoryFile, content), try dialog("write-memory")))
  }

  @Test func aRelativePathResolvesAgainstTheCardsCwd() throws {
    #expect(!ClaudeScreen.shows(memoryCard(cwd: "\(memoryCwd)/Sources"), try dialog("write-memory")))
    #expect(!ClaudeScreen.shows(memoryCard(cwd: nil), try dialog("write-memory")))
  }

  /// A line that Claude Code did not draw, after the warning or in place of
  /// its end, stays part of the shown path.
  @Test(arguments: [
    [" via a symlink", " Something else"],
    [" via a hard link"],
    [" via a symlink and more"],
  ])
  func aWarningWithOtherLinesIsNotShown(_ rows: [String]) throws {
    let lines = try redrawnDialog("write-memory", " via a symlink", rows)
    #expect(!ClaudeScreen.shows(memoryCard(), lines))
  }

  /// Each tool's dialog has its own verb. Read's warning on an Edit dialog
  /// stays part of the shown path.
  @Test func anotherToolsWarningIsNotShown() throws {
    let warning =
      " This will modify /private/tmp/claude-501/-Users-someone-dev-worktrees-switchboard-someone-write-create-card/00000000-0000-0000-0000-000000000000/"
    let read = warning.replacingOccurrences(of: "This will modify", with: "This will read")
    #expect(
      !ClaudeScreen.shows(editCard(linkedNotes, cwd: symlinkCwd), try redrawnDialog("edit-symlink", warning, [read])))
  }

  /// A warning in place of the path names no file.
  @Test func aWarningWithoutAPathIsNotShown() throws {
    let lines = try redrawnDialog("write-symlink", " link/new.txt", [])
    #expect(!ClaudeScreen.shows(writeCard("\(symlinkCwd)/link/new.txt", "one\ntwo", cwd: symlinkCwd), lines))
  }

  /// Claude Code cuts a path wider than the pane at its start. The dialog
  /// then doesn't show which file the Write creates.
  @Test func aDialogThatCutsThePathIsNotShown() throws {
    let cwd =
      "/private/tmp/claude-501/-Users-someone-dev-worktrees-switchboard-someone-write-create-card/00000000-0000-0000-0000-000000000000/scratchpad/cap/home/dev/worktrees/switchboard/someone/org-filter"
    let file =
      "/Users/someone/.claude-automation/projects/-private-tmp-claude-501--Users-someone-dev-worktrees-switchboard-someone-write-create-card-00000000-0000-0000-0000-000000000000-scratchpad-cap-home-dev-worktrees-switchboard-someone-org-filter/memory/org-filter-status.md"
    let card = memoryCard(file, cwd: cwd)
    #expect(!ClaudeScreen.shows(card, try dialog("write-cut-path")))
    #expect(!ClaudeScreen.mayShow(card, try dialog("write-cut-path")))
  }

}

/// sbd's restart ends every held PermissionRequest hook. Claude Code keeps
/// each dialog open.
@Suite struct RestartKeepsFindableCards {
  func restarted(_ cards: [Card]) -> [Card] {
    var replay = SessionReplay()
    replay.facts.cards = cards
    replay.restarted()
    return replay.facts.cards
  }

  @Test func aFindableCardStaysWithItsHookClosed() {
    let cards = restarted([memoryCard(), bashCard("touch a.txt"), fruitCard()])
    #expect(cards.map(\.hookClosed) == [true, true, true])
  }

  @Test(arguments: [facts(fetchTurn()).cards[0], readCard("/etc/hosts", ["offset": 10]), bashCard(" ")])
  func anUnfindableCardGoes(_ card: Card) {
    #expect(!card.findable)
    #expect(restarted([card]).isEmpty)
  }

  @Test func aDeferredCardStaysAsItWas() {
    var question = fruitCard()
    question.deferred = true
    #expect(restarted([question]) == [question])
  }

}
