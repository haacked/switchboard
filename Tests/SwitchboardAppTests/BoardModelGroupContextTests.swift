import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Accepting a description that Claude wrote, and adding and removing a group's links.
@MainActor
@Suite struct BoardModelGroupContext {
  static let link = GroupLink(id: "l1", title: "RFC", url: "https://example.com/rfc", by: .you, t: 0)

  func model(description: String? = nil, by: Author? = nil, links: [GroupLink]? = nil) -> (BoardModel, SentRequests) {
    let (model, sent) = recordingModel()
    model.groups = [
      GroupSummary(
        SessionGroup(id: "g1", name: "Flags", description: description, descriptionBy: by, created: 0, links: links),
        sessions: [])
    ]
    return (model, sent)
  }

  /// The requests that sbd got before a probe that the test sends last. `perform` sends one request at a time in
  /// order, so a request that `act` queued arrives before the probe.
  func requests(_ model: BoardModel, _ sent: SentRequests) async -> [(op: String, args: [String: JSON])] {
    model.perform("probe", [:])
    await sent.wait(for: "probe")
    return sent.value.filter { $0.op != "probe" }
  }

  // MARK: Accept

  @Test func acceptSavesTheSameTextAsYoursAndShowsItBeforeSbdAnswers() async {
    let (model, sent) = model(description: "Ship the cache.", by: .claude)

    model.acceptGroupDescription("g1")

    #expect(model.groups[0].description == "Ship the cache.")
    #expect(model.groups[0].descriptionBy == .you)
    let got = await requests(model, sent)
    #expect(got.map(\.op) == ["group-describe"])
    #expect(got.first?.args == ["group": "g1", "text": "Ship the cache.", "by": "you"])
  }

  @Test(arguments: [nil, Author.you]) func acceptSendsNothingForADescriptionYouWrote(_ by: Author?) async {
    let (model, sent) = model(description: "Ship the cache.", by: by)

    model.acceptGroupDescription("g1")

    #expect(await requests(model, sent).isEmpty)
  }

  @Test func acceptSendsNothingWithoutADescription() async {
    let (model, sent) = model()

    model.acceptGroupDescription("g1")

    #expect(await requests(model, sent).isEmpty)
  }

  /// The description field saves when it loses focus. Opening it and leaving the text as it was must not accept
  /// Claude's text.
  @Test func anUnchangedEditKeepsClaudeAsTheAuthor() async {
    let (model, sent) = model(description: "Ship the cache.", by: .claude)

    model.describeGroup("g1", "Ship the cache.")

    #expect(await requests(model, sent).isEmpty)
    #expect(model.groups[0].descriptionBy == .claude)
  }

  @Test func anEditThatChangesClaudesTextMakesItYours() async {
    let (model, sent) = model(description: "Ship the cache.", by: .claude)

    model.describeGroup("g1", "Ship the flag cache.")

    #expect(model.groups[0].descriptionBy == nil)
    let got = await requests(model, sent)
    #expect(got.first?.args == ["group": "g1", "text": "Ship the flag cache.", "by": "you"])
  }

  // MARK: Links

  @Test func addSendsTheTrimmedURLAndTitle() async {
    let (model, sent) = model()

    model.addGroupLink("g1", url: "  https://example.com/rfc \n", title: " The  RFC ")

    let got = await requests(model, sent)
    #expect(got.map(\.op) == ["group-link-add"])
    #expect(got.first?.args == ["group": "g1", "url": "https://example.com/rfc", "title": "The RFC", "by": "you"])
  }

  @Test func addWithABlankTitleLeavesTheTitleToSbd() async {
    let (model, sent) = model()

    model.addGroupLink("g1", url: "https://example.com/rfc", title: "  ")

    #expect(await requests(model, sent).first?.args == ["group": "g1", "url": "https://example.com/rfc", "by": "you"])
  }

  @Test(arguments: ["", "example.com/rfc", "ftp://example.com/rfc", "https://example.com/a b"])
  func addRefusesAURLThatSbdWouldRefuse(_ url: String) async {
    let (model, sent) = model()
    var added = false

    model.addGroupLink("g1", url: url, title: "") { added = true }

    #expect(model.actionError != nil)
    #expect(await requests(model, sent).isEmpty)
    #expect(!added)
  }

  @Test func addRefusesATitleOverTheLimit() async {
    let (model, sent) = model()

    model.addGroupLink(
      "g1", url: "https://example.com/rfc", title: String(repeating: "a", count: GroupLink.titleLimit + 1))

    #expect(model.actionError?.contains("\(GroupLink.titleLimit)") == true)
    #expect(await requests(model, sent).isEmpty)
  }

  @Test func removeSendsTheLink() async {
    let (model, sent) = model(links: [Self.link])

    model.removeGroupLink("g1", link: "l1")

    let got = await requests(model, sent)
    #expect(got.map(\.op) == ["group-link-rm"])
    #expect(got.first?.args == ["group": "g1", "link": "l1", "by": "you"])
  }
}
