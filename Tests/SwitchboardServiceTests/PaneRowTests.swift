import Testing

@testable import SwitchboardService

@Suite struct PaneRowTests {
  @Test func readsALivePane() {
    let rows = PaneRow.parse("s9azgg-claude\t5601\t0\t2\n")
    #expect(rows["s9azgg-claude"]?.pid == 5601)
    #expect(rows["s9azgg-claude"]?.dead == false)
    #expect(rows["s9azgg-claude"]?.clients == 2)
  }

  /// tmux 3.8 prints no pid for a pane whose program exited. 3.7 printed the
  /// old pid. This is the output of tmux 3.8 on a GitHub Actions runner.
  @Test func keepsADeadPaneThatTmuxGivesNoPid() {
    let rows = PaneRow.parse("s9azgg-claude\t\t1\t0\ns9azgg-shell\t5574\t0\t0\n")
    #expect(Set(rows.keys) == ["s9azgg-claude", "s9azgg-shell"])
    #expect(rows["s9azgg-claude"]?.dead == true)
    #expect(rows["s9azgg-claude"]?.pid == 0)
    #expect(rows["s9azgg-shell"]?.pid == 5574)
  }

  @Test func keepsAPaneWhoseOtherFieldsAreEmpty() {
    let rows = PaneRow.parse("a\t\t\t\nb\t7\t0\t\n")
    #expect(rows["a"]?.dead == false)
    #expect(rows["a"]?.pid == 0)
    #expect(rows["a"]?.clients == 0)
    #expect(rows["b"]?.pid == 7)
    #expect(rows["b"]?.clients == 0)
  }

  @Test func keepsAPaneWithMissingTrailingFields() {
    #expect(PaneRow.parse("a\t5\n")["a"]?.pid == 5)
    #expect(PaneRow.parse("a\n")["a"] != nil)
  }

  @Test func skipsABlankLine() {
    #expect(PaneRow.parse("\n\t\t\t\n").isEmpty)
    #expect(PaneRow.parse("").isEmpty)
  }
}
