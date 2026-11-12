import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A choice in the server menu of a Manager pane, and the arguments that `manager-mcp` gets for it.
enum ServerMenuChoice: CaseIterable, Sendable {
  case add, remove, everyServer, switchboardOnly

  var args: [String: JSON] {
    switch self {
    case .add: ["session": "m", "add": ["grafana"]]
    case .remove: ["session": "m", "rm": ["grafana"]]
    case .everyServer: ["session": "m", "all": true]
    case .switchboardOnly: ["session": "m", "none": true]
    }
  }
}

@MainActor
@Suite struct ManagerPane {
  static let refusal = "Cache work loads every server. Run --none first, then add the ones it needs"

  /// sbd's answer to `manager-mcp` for conversation `m`.
  func answer(servers: JSON, pending: Bool) -> JSON {
    [
      "session": "m", "name": "Cache work", "servers": servers, "available": ["grafana", "posthog-db"],
      "pending": .bool(pending),
    ]
  }

  /// A model whose sbd answers `manager-mcp` with `answer` and every other request with null.
  func answeringModel(_ answer: JSON) -> BoardModel {
    let model = offlineModel()
    model.send = { op, _ in op == "manager-mcp" ? answer : .null }
    return model
  }

  func change(_ model: BoardModel, _ choice: ServerMenuChoice) {
    switch choice {
    case .add: model.changeMCPServers("m", .add("grafana"))
    case .remove: model.changeMCPServers("m", .remove("grafana"))
    case .everyServer: model.changeMCPServers("m", .all)
    case .switchboardOnly: model.changeMCPServers("m", .none)
    }
  }

  // MARK: Server menu

  @Test func loadMCPServersAsksForTheConversationsServers() async {
    let sent = await firstRequest { $0.loadMCPServers("m") }

    #expect(sent.op == "manager-mcp")
    #expect(sent.args == ["session": "m"])
  }

  @Test(arguments: ServerMenuChoice.allCases)
  func eachMenuChoiceSendsItsOneChangeToManagerMCP(_ choice: ServerMenuChoice) async {
    let sent = await firstRequest { change($0, choice) }

    #expect(sent.op == "manager-mcp")
    #expect(sent.args == choice.args)
  }

  @Test func loadMCPServersKeepsTheAnswerByConversation() async {
    let model = answeringModel(answer(servers: ["grafana"], pending: false))

    model.loadMCPServers("m")

    await settle { model.mcpAnswers["m"] != nil }
    #expect(model.mcpAnswers["m"]?.servers == ["grafana"])
    #expect(model.mcpAnswers["m"]?.available == ["grafana", "posthog-db"])
    #expect(model.mcpAnswers["m"]?.pending == false)
  }

  @Test func loadMCPServersKeepsTheFullSetupAsNoList() async {
    let model = answeringModel(answer(servers: .null, pending: false))

    model.loadMCPServers("m")

    await settle { model.mcpAnswers["m"] != nil }
    #expect(model.mcpAnswers["m"] != nil)
    #expect(model.mcpAnswers["m"]?.servers == nil)
  }

  @Test func aChangeKeepsItsAnswerWithPending() async {
    let model = answeringModel(answer(servers: ["grafana"], pending: true))

    model.changeMCPServers("m", .add("grafana"))

    await settle { model.mcpAnswers["m"] != nil }
    #expect(model.mcpAnswers["m"]?.servers == ["grafana"])
    #expect(model.mcpAnswers["m"]?.pending == true)
  }

  @Test func aLaterAnswerReplacesThePendingOne() async {
    let pending = answer(servers: ["grafana"], pending: true)
    let settled = answer(servers: ["grafana"], pending: false)
    let reads = Counter()
    let model = offlineModel()
    model.send = { op, _ in
      guard op == "manager-mcp" else { return .null }
      return reads.increment() == 1 ? pending : settled
    }
    model.changeMCPServers("m", .add("grafana"))
    await settle { model.mcpAnswers["m"]?.pending == true }

    model.loadMCPServers("m")

    await settle { model.mcpAnswers["m"]?.pending == false }
    #expect(model.mcpAnswers["m"]?.pending == false)
  }

  @Test func aFailedLoadShowsNoErrorAndKeepsNoAnswer() async throws {
    let model = offlineModel()
    let tried = Counter()
    model.send = { op, _ in
      guard op == "manager-mcp" else { return .null }
      tried.increment()
      throw APIError("sbd is not running")
    }

    model.loadMCPServers("m")

    await settle { tried.value > 0 }
    try #require(tried.value > 0)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(model.actionError == nil)
    #expect(model.mcpAnswers.isEmpty)
  }

  @Test func aRefusedChangeShowsTheRefusalInTheBanner() async {
    let refusal = Self.refusal
    let model = offlineModel()
    model.send = { op, _ in
      if op == "manager-mcp" { throw APIError(refusal) }
      return .null
    }

    model.changeMCPServers("m", .add("grafana"))

    await settle { model.actionError != nil }
    #expect(model.actionError?.contains(Self.refusal) == true)
  }

  // MARK: New task

  @Test func newTaskOpensTheNewSessionSheet() {
    let model = offlineModel()

    model.openNewSession(parent: "m")

    #expect(model.presentingSheet)
  }

  @Test func newTaskMakesTheConversationTheNewSessionsParent() {
    let model = offlineModel()

    model.openNewSession(parent: "m")

    #expect(model.newSession?.parent == "m")
  }

  @Test func aNewTaskSheetSendsNewWithTheConversationAsParent() async {
    let sent = await firstRequest { model in
      model.openNewSession(parent: "m")
      let form = NewSessionView.Form(group: model.newSession?.group, parent: model.newSession?.parent)
      form.pick(KnownRepo(path: "/Users/me/dev/alpha", name: "alpha", used: 20))
      if let request = form.request(worktree: false, groups: model.groups) {
        model.create(request)
      }
    }

    #expect(sent.op == "new")
    #expect(sent.args["parent"] == "m")
  }

  /// ⌘N, the toolbar +, and the menu items open the sheet without a parent, so a sheet they open after a
  /// dismissed New task must not attach the new session to that conversation.
  @Test func theSheetThatOpensAfterADismissedNewTaskSendsNewWithNoParent() async {
    let sent = await firstRequest { model in
      model.openNewSession(parent: "m")
      #expect(model.newSession?.parent == "m")
      model.newSession = nil
      model.openNewSession()
      let form = NewSessionView.Form(group: model.newSession?.group, parent: model.newSession?.parent)
      form.pick(KnownRepo(path: "/Users/me/dev/alpha", name: "alpha", used: 20))
      if let request = form.request(worktree: false, groups: model.groups) {
        model.create(request)
      }
    }

    #expect(sent.op == "new")
    #expect(sent.args["parent"] == nil)
  }

  // MARK: The default account of a New task

  @Test func theDefaultAccountOfANewTaskNamesTheConversationAndItsAccount() {
    var parent = needsItem("m", manager: true)
    parent.name = "Cache work"
    parent.account = "/Users/me/.claude-max"

    let label = NewSessionView.defaultAccountLabel(parent: parent, active: nil)

    #expect(label == "Same as Cache work (max)")
  }

  @Test func theDefaultAccountOfANewTaskWhoseConversationRecordedNoAccountNamesTheConversation() {
    var parent = needsItem("m", manager: true)
    parent.name = "Cache work"

    #expect(NewSessionView.defaultAccountLabel(parent: parent, active: nil) == "Same as Cache work")
  }

  @Test func theDefaultAccountWithoutAParentNamesTheActiveAccount() {
    let active = AccountInfo(name: "max", folder: "/Users/me/.claude-max", active: true, sessions: 0)

    #expect(NewSessionView.defaultAccountLabel(parent: nil, active: active) == "Active (max)")
  }
}

/// The app decodes sbd's `manager-mcp` answer, whose `servers` is null for the full setup.
@Suite struct ManagerPaneMCPAnswer {
  @Test(
    arguments: [
      (#"{"session":"m","name":"Cache work","available":["grafana"],"pending":false}"#, nil),
      (#"{"session":"m","name":"Cache work","servers":null,"available":["grafana"],"pending":false}"#, nil),
      (#"{"session":"m","name":"Cache work","servers":[],"available":["grafana"],"pending":false}"#, []),
      (
        #"{"session":"m","name":"Cache work","servers":["grafana"],"available":["grafana"],"pending":true}"#,
        ["grafana"]
      ),
    ] as [(String, [String]?)])
  func serversDecodesNullOrMissingAsTheFullSetup(_ text: String, _ servers: [String]?) throws {
    let answer = try JSONCoding.decode(ManagerMCPAnswer.self, from: text)

    #expect(answer.servers == servers)
  }

  @Test func theAnswerDecodesEveryField() throws {
    let text =
      #"{"session":"m","name":"Cache work","servers":["grafana"],"available":["grafana","posthog-db"],"pending":true}"#

    let answer = try JSONCoding.decode(ManagerMCPAnswer.self, from: text)

    #expect(answer.session == "m")
    #expect(answer.name == "Cache work")
    #expect(answer.available == ["grafana", "posthog-db"])
    #expect(answer.pending)
  }
}
