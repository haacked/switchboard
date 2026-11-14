import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ProcessTableTests {
  /// Output of `ps -axo pid=,ppid=,pgid=,command=`, which right-aligns the numbers. Children of pid 7 are out of
  /// pid order, as ps prints them at a tty boundary, and a child of pid 1 sits between them.
  private static let psOutput = """
        1     0     1 /sbin/launchd
       50     7    50 /bin/zsh -l
        7     1     7 /usr/bin/login -pfl haacked
       42     7    42 claude --resume  x
       99     1    99 /usr/sbin/syslogd
       60     7    50 /bin/sh -c 'sleep 30'
    """

  // MARK: children(of:)

  /// `findClaude` takes the first match on a level, so a sort would change which pid it picks.
  @Test func childrenKeepTheOrderOfTheInput() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.children(of: 7).map(\.pid) == [50, 42, 60])
  }

  @Test func childrenHoldOnlyTheRowsWhoseParentIsThePid() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.children(of: 1).map(\.pid) == [7, 99])
  }

  @Test func childrenOfAPidWithNoChildrenAreEmpty() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.children(of: 42).isEmpty)
  }

  // MARK: row(_:)

  /// `backgroundJobs` counts a child that leads its own process group, so a swapped pgid miscounts jobs.
  @Test func rowHoldsThePidParentAndProcessGroup() throws {
    let table = ProcessTable.parse(Self.psOutput)

    let row = try #require(table.row(60))

    #expect(row.pid == 60)
    #expect(row.ppid == 7)
    #expect(row.pgid == 50)
  }

  @Test func rowOfAPidThatIsNotListedIsNil() {
    #expect(ProcessTable.parse(Self.psOutput).row(12345) == nil)
  }

  // MARK: command(of:)

  @Test func commandKeepsTheWholeFourthColumn() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.command(of: 7) == "/usr/bin/login -pfl haacked")
  }

  @Test func commandKeepsAQuotedArgumentWithASpace() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.command(of: 60) == "/bin/sh -c 'sleep 30'")
  }

  @Test func commandKeepsTwoSpacesInsideTheCommand() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(table.command(of: 42) == "claude --resume  x")
  }

  @Test func commandThatIsANumberIsKeptAsText() {
    let table = ProcessTable.parse("12 1 12 42\n")

    #expect(table.command(of: 12) == "42")
  }

  @Test(arguments: ["12 1 12", "12 1 12 ", "   12     1    12"])
  func commandOfARowWithNoCommandIsEmpty(line: String) {
    let table = ProcessTable.parse(line + "\n")

    #expect(table.command(of: 12) == "")
  }

  /// A nil command never matches claude, so a caller can tell an unlisted pid from a listed pid with no command.
  @Test func commandOfAPidThatIsNotListedIsNil() {
    #expect(ProcessTable.parse(Self.psOutput).command(of: 12345) == nil)
  }

  // MARK: Lines that are not rows

  @Test(arguments: [
    "13 1",
    "13",
    "13 1 x /bin/cat",
    "x 1 13 /bin/cat",
    "13 y 13 /bin/cat",
    "PID PPID PGID COMMAND",
    "",
    "   ",
  ])
  func aLineWithoutThreeNumbersIsSkipped(line: String) {
    let table = ProcessTable.parse("  10     1    10 /bin/a\n\(line)\n  11     1    11 /bin/b\n")

    #expect(table.children(of: 1).map(\.pid) == [10, 11])
    #expect(table.row(13) == nil)
  }

  @Test func rowsAfterASkippedLineKeepTheirCommands() {
    let table = ProcessTable.parse("  10     1    10 /bin/a\n13 1 x /bin/cat\n  11     1    11 /bin/b --flag\n")

    #expect(table.command(of: 11) == "/bin/b --flag")
  }

  /// ps prints a newline in a command raw, so the rest of that command can read as a second row for a pid.
  @Test func aPidListedTwiceAnswersFromItsFirstRow() throws {
    let table = ProcessTable.parse("  10     1    10 /bin/a\n  10     2     3 /bin/b\n")

    let row = try #require(table.row(10))

    #expect(row.ppid == 1)
    #expect(row.pgid == 10)
    #expect(table.command(of: 10) == "/bin/a")
  }

  // MARK: all

  @Test func allHoldsEveryRow() {
    let table = ProcessTable.parse(Self.psOutput)

    #expect(Set(table.all.map(\.pid)) == [1, 50, 7, 42, 99, 60])
  }

  // MARK: descendants(of:)

  @Test func descendantsIncludeTheRootsAndEveryLevelBelow() {
    let table = ProcessTable.parse("2 1 2 a\n3 2 3 b\n4 3 4 c\n5 9 5 d\n")

    #expect(table.descendants(of: [1]) == [1, 2, 3, 4])
  }

  @Test func descendantsOfSeveralRootsHoldEachTree() {
    let table = ProcessTable.parse("2 1 2 a\n3 2 3 b\n5 9 5 d\n6 8 6 e\n")

    #expect(table.descendants(of: [1, 9]) == [1, 2, 3, 9, 5])
  }

  @Test func descendantsOfARootThatIsNotListedHoldOnlyTheRoot() {
    let table = ProcessTable.parse("2 1 2 a\n")

    #expect(table.descendants(of: [77]) == [77])
  }

  @Test func descendantsOfNoRootsAreEmpty() {
    let table = ProcessTable.parse("2 1 2 a\n")

    #expect(table.descendants(of: []).isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func descendantsOfATwoProcessCycleEnd() {
    let table = ProcessTable.parse("5 6 5 a\n6 5 6 b\n")

    #expect(table.descendants(of: [5]) == [5, 6])
  }

  @Test(.timeLimit(.minutes(1))) func descendantsOfAThreeProcessCycleEnd() {
    let table = ProcessTable.parse("5 7 5 a\n6 5 6 b\n7 6 7 c\n")

    #expect(table.descendants(of: [6]) == [5, 6, 7])
  }

  @Test(.timeLimit(.minutes(1))) func descendantsOfAProcessThatIsItsOwnParentEnd() {
    let table = ProcessTable.parse("7 7 7 a\n8 7 8 b\n")

    #expect(table.descendants(of: [7]) == [7, 8])
  }

  // MARK: Empty tables

  @Test func anEmptyTableHasNoRows() {
    #expect(ProcessTable().all.isEmpty)
  }

  @Test func anEmptyTableHasNoChildren() {
    #expect(ProcessTable().children(of: 1).isEmpty)
  }

  @Test func anEmptyTableHasNoCommands() {
    #expect(ProcessTable().command(of: 1) == nil)
  }

  @Test func descendantsInAnEmptyTableHoldOnlyTheRoots() {
    #expect(ProcessTable().descendants(of: [1, 2]) == [1, 2])
  }

  @Test func parsingNoTextGivesAnEmptyTable() {
    let table = ProcessTable.parse("")

    #expect(table.all.isEmpty)
    #expect(table.children(of: 0).isEmpty)
  }
}
