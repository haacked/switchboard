import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Accepting a description that Claude wrote, and adding a link to a group.
@MainActor
@Suite struct BoardModelGroupContext {
  func model(description: String? = nil, by: Author? = nil) -> (BoardModel, SentRequests) {
    let (model, sent) = recordingModel()
    model.groups = [
      GroupSummary(
        SessionGroup(id: "g1", name: "Flags", description: description, descriptionBy: by, created: 0),
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

    model.describeGroup("g1", "Ship the cache.", opened: "Ship the cache.")

    #expect(await requests(model, sent).isEmpty)
    #expect(model.groups[0].descriptionBy == .claude)
  }

  @Test func anEditThatChangesClaudesTextMakesItYours() async {
    let (model, sent) = model(description: "Ship the cache.", by: .claude)

    model.describeGroup("g1", "Ship the flag cache.", opened: "Ship the cache.")

    #expect(model.groups[0].descriptionBy == nil)
    let got = await requests(model, sent)
    #expect(got.first?.args == ["group": "g1", "text": "Ship the flag cache.", "by": "you"])
  }

  /// Claude rewrites the description while the field is open with the old text. Leaving the field unchanged must not
  /// replace Claude's newer text with the old text as yours.
  @Test func anUnchangedDraftKeepsTextThatSbdChangedWhileTheFieldWasOpen() async {
    let (model, sent) = model(description: "Ship the flag cache.", by: .claude)

    #expect(model.describeGroup("g1", "Ship the cache.", opened: "Ship the cache."))

    #expect(await requests(model, sent).isEmpty)
    #expect(model.groups[0].description == "Ship the flag cache.")
    #expect(model.groups[0].descriptionBy == .claude)
  }

  /// Claude describes the group while the field is open on an empty group. Leaving the field blank must not clear
  /// Claude's text.
  @Test func aBlankDraftKeepsADescriptionAddedWhileTheFieldWasOpen() async {
    let (model, sent) = model(description: "Ship the cache.", by: .claude)

    #expect(model.describeGroup("g1", "  ", opened: nil))

    #expect(await requests(model, sent).isEmpty)
    #expect(model.groups[0].description == "Ship the cache.")
  }

  @Test func aDraftOverTheLimitIsRefusedEvenWhenTheFieldOpenedEmpty() async {
    let (model, sent) = model()

    #expect(!model.describeGroup("g1", String(repeating: "a", count: SessionGroup.descriptionLimit + 1), opened: nil))

    #expect(model.actionError != nil)
    #expect(await requests(model, sent).isEmpty)
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

  /// The add form clears its fields only when `added` runs.
  @Test func addRunsAddedOnceSbdStoresTheLink() async {
    let (model, sent) = model()
    var added = false

    model.addGroupLink("g1", url: "https://example.com/rfc", title: "") { added = true }

    await sent.wait(for: "group-link-add")
    await settle { added }
    #expect(added)
  }

  /// A refusal from sbd, such as a URL that the group already has, keeps what the user typed.
  @Test func addDoesNotRunAddedWhenSbdRefusesTheLink() async {
    let (model, sent) = recordingModel(refuse: { op, _ in
      op == "group-link-add" ? "Flags already has a link to https://example.com/rfc" : nil
    })
    model.groups = [GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0), sessions: [])]
    var added = false

    model.addGroupLink("g1", url: "https://example.com/rfc", title: "") { added = true }

    await sent.wait(for: "group-link-add")
    await settle { model.actionError != nil }
    #expect(model.actionError?.contains("already has a link") == true)
    #expect(!added)
  }

  @Test func addRefusesATitleOverTheLimit() async {
    let (model, sent) = model()

    model.addGroupLink(
      "g1", url: "https://example.com/rfc", title: String(repeating: "a", count: ExternalLink.titleLimit + 1))

    #expect(model.actionError?.contains("\(ExternalLink.titleLimit)") == true)
    #expect(await requests(model, sent).isEmpty)
  }
}
