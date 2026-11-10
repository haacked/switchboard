import Testing

@testable import SwitchboardCore

/// The marks a parent records, starting from `.fresh`, as its child shows each PR number in turn.
private func heard(_ prs: [Int?]) -> [ChildMark] {
  var marks = [ChildMark.fresh]
  for pr in prs { marks.append(marks.last!.updated(to: ChildMark(state: .working, pr: pr))) }
  return marks
}

@Suite struct ParentNoticeTests {
  func lines(_ before: ChildMark, _ after: ChildMark, url: String? = nil) -> [String] {
    ParentNotice.lines(name: "fix", id: "s1", before: before, after: after, reason: "answer: which?", prURL: url)
  }

  @Test func saysWhenAChildNeedsYou() {
    let result = lines(.fresh, ChildMark(state: .needsYou, pr: nil))
    #expect(result == ["fix (s1) needs you: answer: which?"])
  }

  @Test func saysWhenAChildIsDone() {
    #expect(lines(.fresh, ChildMark(state: .done, pr: nil)) == ["fix (s1) is done"])
  }

  @Test func saysWhenAChildOpensAPR() {
    let result = lines(.fresh, ChildMark(state: .working, pr: 7), url: "https://github.com/o/r/pull/7")
    #expect(result == ["fix (s1) opened PR #7: https://github.com/o/r/pull/7"])
  }

  @Test func listsAPRBeforeTheStateItCaused() {
    let result = lines(.fresh, ChildMark(state: .needsYou, pr: 7))
    #expect(result.count == 2)
    #expect(result[0].contains("opened PR #7"))
    #expect(result[1].contains("needs you"))
  }

  @Test func saysNothingForOtherChanges() {
    #expect(lines(.fresh, ChildMark(state: .canContinue, pr: nil)).isEmpty)
    #expect(lines(.fresh, ChildMark(state: .waiting, pr: nil)).isEmpty)
    let needs = ChildMark(state: .needsYou, pr: 7)
    #expect(lines(needs, needs).isEmpty)
    #expect(lines(ChildMark(state: .working, pr: 7), ChildMark(state: .working, pr: 7)).isEmpty)
  }

  @Test func saysAgainWhenTheChildReturnsToNeedsYou() {
    let needs = ChildMark(state: .needsYou, pr: nil)
    #expect(lines(.fresh, needs).count == 1)
    #expect(lines(needs, .fresh).isEmpty)
    #expect(lines(.fresh, needs).count == 1)
  }

  func announced(_ prs: [Int?]) -> [String] {
    let marks = heard(prs)
    return zip(marks, marks.dropFirst()).flatMap { lines($0, $1) }
  }

  @Test func saysNothingWhenAHeardPRDropsOutAndReturns() {
    #expect(announced([26, nil, 26]) == ["fix (s1) opened PR #26"])
  }

  @Test func saysWhenAPRThatReturnsHasANewNumber() {
    #expect(announced([26, nil, 28]) == ["fix (s1) opened PR #26", "fix (s1) opened PR #28"])
  }

  @Test func saysNothingWhenAnEarlierHeardNumberReturns() {
    #expect(announced([26, 28, nil, 26]) == ["fix (s1) opened PR #26", "fix (s1) opened PR #28"])
  }

  @Test func keepsTheHeardNumbersWhenTheChildIsSeenAfresh() {
    let marks = heard([26])
    #expect(marks.last!.updated(to: .fresh).heardPRs == [26])
  }

  @Test func saysEachLineOnce() {
    let message = ParentNotice.message(["a needs you", "b is done", "a needs you"])
    #expect(message == "Switchboard: sessions you started changed: b is done; a needs you.")
  }

  @Test func endsWithTheChildsLatestLine() {
    let message = ParentNotice.message(["a needs you: read", "a needs you: answer: Q", "a needs you: read"])
    #expect(message == "Switchboard: sessions you started changed: a needs you: answer: Q; a needs you: read.")
  }

  @Test func countsOnlyTheDistinctLinesPastTheLimit() {
    let many = (1...25).map { "s\($0) is done" }
    #expect(ParentNotice.message(many + many).hasSuffix("and 5 more."))
  }

  @Test func joinsEveryChangeIntoOneLine() {
    let message = ParentNotice.message(["a needs you", "b is done"])
    #expect(message == "Switchboard: sessions you started changed: a needs you; b is done.")
    #expect(!message.contains("\n"))
  }

  @Test func countsTheLinesPastTheLimit() {
    let many = (1...25).map { "s\($0) is done" }
    let message = ParentNotice.message(many)
    #expect(message.contains("s20 is done"))
    #expect(!message.contains("s21 is done"))
    #expect(message.hasSuffix("and 5 more."))
  }
}

@Suite struct ParentDigestTests {
  func line(_ heard: ChildMark, _ now: ChildMark, url: String? = nil) -> String? {
    ParentDigest.line(name: "fix", id: "s1", heard: heard, now: now, reason: "answer: which?", prURL: url)
  }

  @Test func putsEveryChangeOfAChildOnOneLine() {
    let result = line(.fresh, ChildMark(state: .needsYou, pr: 7), url: "https://github.com/o/r/pull/7")
    #expect(result == "fix (s1): opened PR #7: https://github.com/o/r/pull/7; needs you: answer: which?")
    #expect(line(.fresh, ChildMark(state: .done, pr: nil)) == "fix (s1): done")
    #expect(line(.fresh, ChildMark(state: .readyToMerge, pr: nil)) == "fix (s1): answer: which?")
  }

  @Test func hasNoLineForAChildThatIsBackWhereItsParentLastHeard() {
    let needs = ChildMark(state: .needsYou, pr: nil)
    #expect(line(needs, needs) == nil)
    #expect(line(.fresh, ChildMark(state: .canContinue, pr: nil)) == nil)
  }

  @Test func hasNoLineForAHeardPRThatDropsOutAndReturns() {
    let back = heard([26, nil, 26])
    #expect(line(back[1], back[2]) == nil)
    #expect(line(back[2], back[3]) == nil)
    let other = heard([26, nil, 28])
    #expect(line(other[2], other[3]) == "fix (s1): opened PR #28")
  }

  @Test func listsTheLinesThenTheCounts() {
    let text = ParentDigest.text(["a (s1): done"], elsewhere: BoardCounts(needsYou: 2, readyToMerge: 1))
    #expect(
      text == """
        Switchboard: what changed since your last turn.
        Sessions you started:
        - a (s1): done
        Other sessions: 2 in Needs you, 1 in Ready to merge.
        """)
  }

  @Test func countsTheLinesPastTheLimit() {
    let text = ParentDigest.text((1...18).map { "s\($0): done" }, elsewhere: BoardCounts())
    #expect(text.contains("- s15: done"))
    #expect(!text.contains("- s16: done"))
    #expect(text.contains("- and 3 more\n"))
  }

  @Test func answersTheHookWithTheTextAsAdditionalContext() {
    let output = ParentDigest.hookOutput("t")
    #expect(output["hookSpecificOutput"]?["hookEventName"] == "UserPromptSubmit")
    #expect(output["hookSpecificOutput"]?["additionalContext"] == "t")
  }

  @Test func onlyAWorkSessionHearsChildNotices() {
    #expect(SessionKind.work.hearsChildNotices)
    #expect(!SessionKind.manager.hearsChildNotices)
    #expect(!SessionKind.chat.hearsChildNotices)
  }
}
