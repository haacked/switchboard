import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let conversation = "c1"
private let other = "c2"
private let work = "w1"
private let chat = "g1"
private let theOperator = "o1"
private let created: Int64 = 1_800_000_000_000

/// A pid that names no pane of the test's ancestry. No test signals it, because `snapshot.claudePids` stays empty.
private let unrelatedPane = 4242

private func dateWait(_ id: String, by: Author = .you, from: Wait.SessionTarget? = nil) -> Wait {
  var w = Wait(id: id, kind: .date, until: created + 3_600_000, by: by, created: created, then: .notify)
  w.handedFrom = from
  return w
}

private func schedule(_ id: String) throws -> Schedule {
  try ScheduleRequest(every: "30m", prompt: "check the queue", by: nil).makeSchedule(id: id, now: created)
}

private func pause(until: Wait? = nil, message: String? = nil) -> Pause {
  Pause(by: .you, since: created, until: until, message: message)
}

private func session(_ id: String, _ kind: SessionKind) -> Session {
  var s = makeSession(id, name: "\(kind.rawValue) \(id)")
  switch kind {
  case .manager: s.manager = true
  case .operator:
    s.manager = true
    s.isOperator = true
  case .chat: s.chat = "Flags"
  case .work: break
  }
  return s
}

/// A service whose entries hold one session of each kind. The service never loads, so it starts no tmux server and
/// no claude.
private func withSessions(_ body: (Service) throws -> Void) throws {
  try withService { service, _ in
    service.queue.sync {
      for (id, kind) in [
        (conversation, SessionKind.manager), (other, .manager), (work, .work), (chat, .chat),
        (theOperator, .operator),
      ] {
        service.entries[id] = Service.Entry(session: session(id, kind))
      }
    }
    try body(service)
  }
}

/// `extra` with `session` set to the conversation.
private func conversationArgs(_ extra: [String: JSON]) -> JSON {
  JSON.object(extra.merging(["session": .string(conversation)]) { $1 })
}

/// The error that `body` throws, or nil.
private func refusal(_ body: () throws -> Void) -> String? {
  do {
    try body()
    return nil
  } catch {
    return "\(error)"
  }
}

/// The removal guard for a conversation's own waits and schedules, at both check points, and the checks that keep
/// `manager-end` to the user.
@Suite struct ConversationEndGuardTests {
  // MARK: refuseConversationRemoval (Risk 1)

  /// The waits, schedules, and `endingDrops` of the conversation, and whether the guard refuses.
  struct Held: Sendable, CustomTestStringConvertible {
    let label: String
    let waits: [String]
    let schedules: [String]
    let drops: [String]?
    /// The ids that the refusal names, or nil when the guard lets the removal through.
    let unnamed: [String]?
    /// The id of the condition of the conversation's pause, or nil when it isn't paused on a condition.
    var pauseUntil: String? = nil
    var testDescription: String { label }
  }

  static let held: [Held] = [
    Held(label: "nothing of its own", waits: [], schedules: [], drops: nil, unnamed: nil),
    Held(label: "a wait and no drops", waits: ["w1"], schedules: [], drops: nil, unnamed: ["w1"]),
    Held(label: "a wait and empty drops", waits: ["w1"], schedules: [], drops: [], unnamed: ["w1"]),
    Held(label: "a schedule and no drops", waits: [], schedules: ["r1"], drops: nil, unnamed: ["r1"]),
    Held(label: "two waits, one dropped", waits: ["w1", "w2"], schedules: [], drops: ["w1"], unnamed: ["w2"]),
    Held(
      label: "a wait and a schedule, the wait dropped", waits: ["w1"], schedules: ["r1"], drops: ["w1"],
      unnamed: ["r1"]),
    Held(label: "every id dropped", waits: ["w1", "w2"], schedules: ["r1"], drops: ["w1", "w2", "r1"], unnamed: nil),
    Held(label: "drops that name more than it holds", waits: ["w1"], schedules: [], drops: ["w1", "w9"], unnamed: nil),
    Held(label: "a drop whose id differs in case", waits: ["w1"], schedules: [], drops: ["W1"], unnamed: ["w1"]),
    Held(
      label: "a pause condition and no drops", waits: [], schedules: [], drops: nil, unnamed: ["w2"], pauseUntil: "w2"),
    Held(
      label: "a wait and a pause condition, the wait dropped", waits: ["w1"], schedules: [], drops: ["w1"],
      unnamed: ["w2"], pauseUntil: "w2"),
    Held(
      label: "a wait and a pause condition, both dropped", waits: ["w1"], schedules: [], drops: ["w1", "w2"],
      unnamed: nil, pauseUntil: "w2"),
  ]

  /// Gives the conversation the waits and schedules, and sets `endingDrops` for it.
  private func give(_ service: Service, _ h: Held) throws {
    let made = try h.schedules.map(schedule)
    service.queue.sync {
      service.entries[conversation]?.session.waits = h.waits.map { dateWait($0) }
      service.entries[conversation]?.session.schedules = made.isEmpty ? nil : made
      service.entries[conversation]?.session.pause = h.pauseUntil.map { pause(until: dateWait($0)) }
      service.endingDrops[conversation] = h.drops.map(Set.init)
    }
  }

  @Test(arguments: held) func theGuardRefusesExactlyWhenAnOwnIdIsUnnamed(_ h: Held) throws {
    try withSessions { service in
      try give(service, h)

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      guard let unnamed = h.unnamed else {
        #expect(error == nil)
        return
      }
      let text = try #require(error)
      for id in unnamed { #expect(text.contains(id), Comment(rawValue: text)) }
      #expect(text.contains("sb manager end"), Comment(rawValue: text))
      #expect(text.contains("--drop"), Comment(rawValue: text))
    }
  }

  /// Only a Manager conversation's waits and schedules stay with it. The operator has its own guard.
  @Test(arguments: [work, chat, theOperator]) func theGuardLetsAnotherKindOfSessionThrough(_ id: String) throws {
    try withSessions { service in
      let made = try schedule("r1")
      service.queue.sync {
        service.entries[id]?.session.waits = [dateWait("w1")]
        service.entries[id]?.session.schedules = [made]
      }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(id) } }

      #expect(error == nil)
    }
  }

  /// A wait that the conversation handed off sits on the operator, so it never blocks the conversation.
  @Test func aHandedWaitOnTheOperatorDoesNotBlockTheConversation() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[theOperator]?.session.waits = [
          dateWait("w1", by: .claude, from: Wait.SessionTarget(id: conversation, name: "manager c1"))
        ]
      }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      #expect(error == nil)
    }
  }

  /// `endingDrops` of one conversation does not let another conversation's waits go.
  @Test func anotherConversationsDropsDoNotApply() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.waits = [dateWait("w1")]
        service.endingDrops[other] = ["w1"]
      }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      #expect(error?.contains("w1") == true, "\(error ?? "nil")")
    }
  }

  // MARK: Both check points agree (Risk 1)

  @Test(arguments: held.filter { $0.unnamed != nil })
  func removalEntryAndForgetSessionGiveTheGuardsRefusal(_ h: Held) throws {
    try withSessions { service in
      try give(service, h)
      let guarded = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      let atEntry = refusal { _ = try service.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      #expect(guarded != nil)
      #expect(atEntry == guarded)
      #expect(atForget == guarded)
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// The confirmation named w1. w2 landed while claude stopped, after `removalEntry` passed.
  @Test func aWaitThatLandsAfterTheFirstCheckRefusesTheForget() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.waits = [dateWait("w1")]
        service.endingDrops[conversation] = ["w1"]
      }
      _ = try service.removalEntry(conversation, resolving: [], for: .rm)
      service.queue.sync { service.entries[conversation]?.session.waits?.append(dateWait("w2", by: .claude)) }

      let error = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      #expect(error?.contains("w2") == true, "\(error ?? "nil")")
      let kept = service.queue.sync { service.entries[conversation]?.session.waits?.map(\.id) }
      #expect(kept == ["w1", "w2"])
    }
  }

  /// The condition of a pause that the user set while claude stopped resumes the conversation, so the forget
  /// refuses it as it refuses a wait.
  @Test func aPauseConditionThatLandsAfterTheFirstCheckRefusesTheForget() throws {
    try withSessions { service in
      _ = try service.removalEntry(conversation, resolving: [], for: .rm)
      service.queue.sync {
        service.entries[conversation]?.session.pause = pause(until: dateWait("w1"), message: "check #123")
      }

      let error = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      let text = try #require(error)
      #expect(text.contains("w1  Paused by you; resumes when at "), Comment(rawValue: text))
      #expect(text.contains("The resume would send: check #123"), Comment(rawValue: text))
      #expect(text.contains("--drop w1"), Comment(rawValue: text))
      #expect(service.queue.sync { service.entries[conversation]?.session.pause?.until?.id } == "w1")
    }
  }

  /// A pause with no condition and no held message drops nothing the user named.
  @Test(arguments: [nil, "pick up the flag work"] as [String?])
  func aPauseWithNoConditionAndNoHeldMessageLetsTheRemovalThrough(_ message: String?) throws {
    try withSessions { service in
      service.queue.sync { service.entries[conversation]?.session.pause = pause(message: message) }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      #expect(error == nil)
    }
  }

  /// No id names a held message, so no `drop` lets it go. A message can land while claude stops, so the forget
  /// refuses it too.
  @Test(arguments: [nil, "w1"] as [String?])
  func aPausedConversationThatHoldsAMessageIsRefusedAtBothCheckPoints(_ until: String?) throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.pause = pause(until: until.map { dateWait($0) })
        service.entries[conversation]?.pending = [Service.QueuedMessage(text: "the deploy finished", sent: nil)]
        service.endingDrops[conversation] = Set(until.map { [$0] } ?? [])
      }

      let atEntry = refusal { _ = try service.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      let text = try #require(atEntry)
      #expect(text.contains("has 1 message"), Comment(rawValue: text))
      #expect(text.contains("the deploy finished"), Comment(rawValue: text))
      #expect(text.contains("sb resume \(conversation)"), Comment(rawValue: text))
      #expect(!text.contains("sb open"), Comment(rawValue: text))
      #expect(atForget == atEntry)
      #expect(service.queue.sync { service.entries[conversation]?.pending.count } == 1)
    }
  }

  /// A full live cap or a message with images queues a message for a conversation that isn't paused. Its claude
  /// is stopped, so the refusal names `sb open`, which starts it ahead of the live cap's queue.
  @Test func anUnpausedConversationWithAQueuedMessageIsRefusedAtBothCheckPoints() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.pending = [Service.QueuedMessage(text: "the deploy finished", sent: nil)]
      }

      let atEntry = refusal { _ = try service.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      let text = try #require(atEntry)
      #expect(text.contains("has 1 message"), Comment(rawValue: text))
      #expect(text.contains("the deploy finished"), Comment(rawValue: text))
      #expect(text.contains("sb open \(conversation)"), Comment(rawValue: text))
      #expect(!text.contains("paused"), Comment(rawValue: text))
      #expect(atForget == atEntry)
      #expect(service.queue.sync { service.entries[conversation]?.pending.map(\.text) } == ["the deploy finished"])
    }
  }

  /// A paste that claude has not confirmed with its UserPromptSubmit left the queue, so only `inFlight` shows it.
  @Test func aMessageInFlightIsRefusedAtBothCheckPoints() throws {
    try withSessions { service in
      service.queue.sync { service.entries[conversation]?.inFlight = Service.InFlight(created) }

      let atEntry = refusal { _ = try service.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      let text = try #require(atEntry)
      #expect(text.contains("has 1 message"), Comment(rawValue: text))
      #expect(text.contains("a message that claude has not confirmed yet"), Comment(rawValue: text))
      #expect(atForget == atEntry)
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// Each queued message gets a line, and the unconfirmed one counts too.
  @Test func theRefusalCountsAndListsEveryMessage() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.pending = [
          Service.QueuedMessage(text: "the deploy finished", sent: nil),
          Service.QueuedMessage(text: "check #123", sent: nil),
        ]
        service.entries[conversation]?.inFlight = Service.InFlight(created)
      }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      let text = try #require(error)
      #expect(text.contains("has 3 messages on their way"), Comment(rawValue: text))
      #expect(text.contains("  the deploy finished\n  check #123\n  a message that claude"), Comment(rawValue: text))
    }
  }

  /// The message check comes first, because `--drop` can't name a message.
  @Test func dropsDoNotLetAQueuedMessageGo() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.waits = [dateWait("w1")]
        service.entries[conversation]?.pending = [Service.QueuedMessage(text: "the deploy finished", sent: nil)]
        service.endingDrops[conversation] = ["w1"]
      }

      let atEntry = refusal { _ = try service.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      let text = try #require(atEntry)
      #expect(text.contains("the deploy finished"), Comment(rawValue: text))
      #expect(atForget == atEntry)
      let kept = service.queue.sync { service.entries[conversation] }
      #expect(kept?.session.waits?.map(\.id) == ["w1"])
      #expect(kept?.pending.count == 1)
    }
  }

  @Test func aMessageQueuedAfterTheFirstCheckRefusesTheForget() throws {
    try withSessions { service in
      _ = try service.removalEntry(conversation, resolving: [], for: .rm)
      service.queue.sync {
        service.entries[conversation]?.pending.append(Service.QueuedMessage(text: "the deploy finished", sent: nil))
      }

      let error = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      #expect(error?.contains("the deploy finished") == true, "\(error ?? "nil")")
      #expect(service.queue.sync { service.entries[conversation]?.pending.count } == 1)
    }
  }

  @Test func aMessageInFlightAfterTheFirstCheckRefusesTheForget() throws {
    try withSessions { service in
      _ = try service.removalEntry(conversation, resolving: [], for: .rm)
      service.queue.sync { service.entries[conversation]?.inFlight = Service.InFlight(created) }

      let error = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      #expect(error?.contains("not confirmed") == true, "\(error ?? "nil")")
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// The confirmation dropped w1. It resolved while claude stopped, so its resume message is now queued.
  @Test func aDroppedWaitThatResolvesDuringTheStopRefusesTheForget() throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.waits = [dateWait("w1")]
        service.endingDrops[conversation] = ["w1"]
      }
      _ = try service.removalEntry(conversation, resolving: [], for: .rm)
      service.queue.sync {
        service.entries[conversation]?.session.waits = []
        service.entries[conversation]?.pending.append(Service.QueuedMessage(text: "w1 resolved", sent: nil))
      }

      let error = refusal { try service.queue.sync { try service.forgetSession(conversation, resolving: []) } }

      #expect(error?.contains("w1 resolved") == true, "\(error ?? "nil")")
      #expect(service.queue.sync { service.entries[conversation]?.pending.count } == 1)
    }
  }

  /// A claude that runs takes the message once it is ready, so the refusal names no command.
  @Test func aRunningClaudesRefusalSaysToTryAgainLater() throws {
    try withSessions { service in
      service.queue.sync {
        service.mac.snapshot.panes[service.paneName(conversation, .claude)] = PaneRow(
          pid: unrelatedPane, dead: false, clients: 0)
        service.entries[conversation]?.pending = [Service.QueuedMessage(text: "the deploy finished", sent: nil)]
      }

      let error = refusal { try service.queue.sync { try service.refuseConversationRemoval(conversation) } }

      let text = try #require(error)
      #expect(text.hasSuffix("They reach claude once it is ready for them. Try again then."), Comment(rawValue: text))
    }
  }

  // MARK: A launch prompt across a restart of sbd (Risk 1)

  /// What the log holds after a send launched the stopped conversation with its message as the prompt.
  enum AfterLaunch: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case nothing
    case sessionStart
    /// A launch with no prompt, as `sb open` and `sb manager end --new` make.
    case launchWithoutPrompt
    /// The prompt launch's claude exited before it submitted, and a launch with no prompt started claude again.
    case relaunchedWithoutPrompt
    /// Claude submitted the prompt, and its turn ended.
    case promptSubmitted
    /// Claude exited at the trust dialog, so `trust_closed` moved the prompt to the queue.
    case trustClosed

    var testDescription: String { rawValue }

    func events(_ prompt: String) -> [Event] {
      let launch = Event(session: conversation, t: created, kind: "resumed", data: ["prompt": .string(prompt)])
      let start = Event(session: conversation, t: created + 1_000, kind: "SessionStart")
      switch self {
      case .nothing: return [launch]
      case .sessionStart: return [launch, start]
      case .launchWithoutPrompt:
        return [Event(session: conversation, t: created, kind: "resumed", data: ["prompt": .null]), start]
      case .relaunchedWithoutPrompt:
        return [
          launch, start,
          Event(session: conversation, t: created + 5_000, kind: "resumed", data: ["prompt": .null]),
          Event(session: conversation, t: created + 6_000, kind: "SessionStart"),
        ]
      case .promptSubmitted:
        return [
          launch, start,
          Event(session: conversation, t: created + 2_000, kind: "UserPromptSubmit", data: ["prompt": .string(prompt)]),
          Event(session: conversation, t: created + 3_000, kind: "Stop"),
        ]
      case .trustClosed:
        return [
          launch,
          Event(
            session: conversation, t: created + 1_000, kind: "trust_dialog",
            data: ["folder": "/tmp", "prompt": .string(prompt), "launch": .number(Double(created))]),
          Event(session: conversation, t: created + 2_000, kind: "trust_closed", data: ["prompt": .string(prompt)]),
        ]
      }
    }
  }

  /// A restarted sbd reads the conversation from the log. A launch prompt that claude has not submitted is still on
  /// its way, so both check points refuse the removal. A submitted prompt, or a later launch with no prompt, lets it
  /// through. A prompt that `trust_closed` queued counts once, by its text.
  @Test(arguments: AfterLaunch.allCases)
  func aRestartKeepsALaunchPromptThatClaudeHasNotSubmittedOnItsWay(_ after: AfterLaunch) throws {
    try withService { service, home in
      try service.store.save(session(conversation, .manager))
      let prompt = "the deploy finished"
      for event in after.events(prompt) { _ = try service.store.append(event) }
      let restarted = try Service(home: home, sbPath: "/usr/bin/true")
      defer { for link in restarted.hostLinks.values { link.disconnect() } }

      try restarted.load()
      let atEntry = refusal { _ = try restarted.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal {
        try restarted.queue.sync { try restarted.forgetSession(conversation, resolving: []) }
      }

      switch after {
      case .nothing, .sessionStart:
        let text = try #require(atEntry)
        #expect(text.contains("has 1 message"), Comment(rawValue: text))
        #expect(text.contains("a message that claude has not confirmed yet"), Comment(rawValue: text))
        #expect(text.contains("sb open \(conversation)"), Comment(rawValue: text))
        #expect(atForget == atEntry)
        #expect(restarted.queue.sync { restarted.entries[conversation] } != nil)
      case .promptSubmitted, .launchWithoutPrompt, .relaunchedWithoutPrompt:
        #expect(atEntry == nil)
        #expect(atForget == nil)
        #expect(restarted.queue.sync { restarted.entries[conversation] } == nil)
      case .trustClosed:
        let text = try #require(atEntry)
        #expect(text.contains("has 1 message"), Comment(rawValue: text))
        #expect(text.contains(prompt), Comment(rawValue: text))
        #expect(!text.contains("not confirmed"), Comment(rawValue: text))
        #expect(atForget == atEntry)
      }
    }
  }

  /// What the log holds after sbd pasted a message into the running conversation.
  enum AfterPaste: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The paste landed, and claude has not submitted it.
    case delivered
    /// The paste started, and sbd stopped before it recorded `delivered`.
    case pastingOnly
    case submitted
    /// The hook reached sbd before the paste's `delivered` did.
    case submittedBeforeDelivered
    /// A built-in command, for which Claude Code sends no UserPromptSubmit.
    case builtIn

    var testDescription: String { rawValue }

    var text: String { self == .builtIn ? "/compact" : "the deploy finished" }

    var refuses: Bool { self == .delivered || self == .pastingOnly }

    static let pastingAt = created + 2_000

    func events() -> [Event] {
      let message: JSON = .string(text)
      let ready = [
        Event(session: conversation, t: created, kind: "resumed", data: ["prompt": .null]),
        Event(session: conversation, t: created + 1_000, kind: "SessionStart"),
        Event(
          session: conversation, t: created + 1_900, kind: "sent",
          data: ["text": message, "delivery": "pasted", Delivery.awaitsDeliveredKey: true]),
        Event(session: conversation, t: Self.pastingAt, kind: "pasting", data: ["text": message]),
      ]
      let delivered = Event(session: conversation, t: created + 2_100, kind: "delivered", data: ["text": message])
      func submit(_ t: Int64) -> Event {
        Event(session: conversation, t: t, kind: "UserPromptSubmit", data: ["prompt": message])
      }
      switch self {
      case .delivered, .builtIn: return ready + [delivered]
      case .pastingOnly: return ready
      case .submitted: return ready + [delivered, submit(created + 3_000)]
      case .submittedBeforeDelivered: return ready + [submit(created + 2_050), delivered]
      }
    }
  }

  /// A restarted sbd reads a paste that claude has not submitted from the log, so both check points refuse the
  /// removal. The rebuilt mark is the `pasting` event's time, so it holds back a later paste no longer than the mark
  /// before the restart would. A submit, in either order with `delivered`, lets the removal through, and so does a
  /// built-in command, which claude never submits.
  @Test(arguments: AfterPaste.allCases)
  func aRestartKeepsAPasteThatClaudeHasNotSubmittedOnItsWay(_ after: AfterPaste) throws {
    try withService { service, home in
      try service.store.save(session(conversation, .manager))
      for event in after.events() { _ = try service.store.append(event) }
      let restarted = try Service(home: home, sbPath: "/usr/bin/true")
      defer { for link in restarted.hostLinks.values { link.disconnect() } }

      try restarted.load()
      let entry = try #require(restarted.queue.sync { restarted.entries[conversation] })
      let atEntry = refusal { _ = try restarted.removalEntry(conversation, resolving: [], for: .rm) }
      let atForget = refusal {
        try restarted.queue.sync { try restarted.forgetSession(conversation, resolving: []) }
      }

      if after.refuses {
        #expect(entry.inFlight?.since == AfterPaste.pastingAt)
        #expect(!restarted.messageWaiting(entry, now: AfterPaste.pastingAt + Service.inFlightMs))
        let text = try #require(atEntry)
        #expect(text.contains("has 1 message"), Comment(rawValue: text))
        #expect(text.contains("a message that claude has not confirmed yet"), Comment(rawValue: text))
        #expect(atForget == atEntry)
        #expect(restarted.queue.sync { restarted.entries[conversation] } != nil)
      } else {
        #expect(entry.inFlight == nil)
        #expect(atEntry == nil, Comment(rawValue: atEntry ?? ""))
        #expect(atForget == nil, Comment(rawValue: atForget ?? ""))
        #expect(restarted.queue.sync { restarted.entries[conversation] } == nil)
      }
    }
  }

  /// A second `manager-end` on a conversation that one is ending would replace the first one's drops, and its
  /// cleanup would clear them while the first removal runs.
  @Test func aSecondEndOfTheSameConversationIsRefusedAndKeepsTheFirstOnesDrops() throws {
    try withSessions { service in
      service.queue.sync { service.endingDrops[conversation] = ["w1"] }

      let error = refusal {
        _ = try service.managerEnd(.object(["session": .string(conversation), "drop": ["w2"]]), caller: .inProcess)
      }

      #expect(error?.contains("is being deleted") == true, "\(error ?? "nil")")
      #expect(service.queue.sync { service.endingDrops[conversation] } == ["w1"])
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  // MARK: Only the user (Risk 3)

  /// The conversation's turn runs, so a request that passes every check of who sent it stops at the turn's
  /// refusal, which names `sb stop`. No request reaches `remove`.
  private func withBusyConversation(_ body: (Service) throws -> Void) throws {
    try withSessions { service in
      service.queue.sync { service.entries[conversation]?.facts.turnRunning = true }
      try body(service)
    }
  }

  /// `managerEnd` installs a fresh snapshot only when it is newer, so the rows stay.
  private func setPanes(_ service: Service, of id: String, claude: PaneRow, shell: PaneRow) {
    service.queue.sync {
      service.mac.snapshot.taken = .max
      service.mac.snapshot.panes[service.paneName(id, .claude)] = claude
      service.mac.snapshot.panes[service.paneName(id, .shell)] = shell
    }
  }

  private func end(_ service: Service, caller: Caller, _ extra: [String: JSON] = [:]) -> String? {
    refusal { _ = try service.managerEnd(conversationArgs(extra), caller: caller) }
  }

  private var me: Caller { .client(pid: Int(getpid())) }
  private var myPid: Int { Int(getpid()) }

  /// The target's own pane and another session's pane both count.
  @Test(arguments: [conversation, other, work])
  func aCallerBelowAnyLocalSessionsLiveClaudePaneIsRefused(_ owner: String) throws {
    try withBusyConversation { service in
      setPanes(
        service, of: owner, claude: PaneRow(pid: myPid, dead: false, clients: 0),
        shell: PaneRow(pid: unrelatedPane, dead: false, clients: 0))

      let error = end(service, caller: me)

      let text = try #require(error)
      #expect(!text.contains("sb stop"), Comment(rawValue: text))
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// A session's Claude can type into its own shell pane with `tmux send-keys`, so a shell pane counts too.
  @Test(arguments: [conversation, work]) func aCallerBelowAShellPaneIsRefused(_ owner: String) throws {
    try withBusyConversation { service in
      setPanes(
        service, of: owner, claude: PaneRow(pid: unrelatedPane, dead: false, clients: 0),
        shell: PaneRow(pid: myPid, dead: false, clients: 0))

      let error = end(service, caller: me)

      let text = try #require(error)
      #expect(!text.contains("sb stop"), Comment(rawValue: text))
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// A session that runs `tmux new-window` starts a program below sbd's tmux server and outside every pane. The
  /// server is this process's parent here, and the new pane's pid is not in this process's ancestry.
  @Test func aCallerBelowTheTmuxServerOutsideEveryPaneIsRefused() throws {
    try withBusyConversation { service in
      service.queue.sync {
        service.mac.snapshot.taken = .max
        service.mac.snapshot.panes["opened-by-a-session"] = PaneRow(
          pid: unrelatedPane, dead: false, clients: 0, server: Int(getppid()))
      }

      let error = end(service, caller: me)

      let text = try #require(error)
      #expect(text.contains("tmux server"), Comment(rawValue: text))
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  @Test func aCallerInAShellPaneBelowTheTmuxServerIsRefused() throws {
    try withBusyConversation { service in
      setPanes(
        service, of: work, claude: PaneRow(pid: unrelatedPane, dead: false, clients: 0, server: Int(getppid())),
        shell: PaneRow(pid: myPid, dead: false, clients: 0, server: Int(getppid())))

      let error = end(service, caller: me)

      let text = try #require(error)
      #expect(!text.contains("sb stop"), Comment(rawValue: text))
      #expect(service.queue.sync { service.entries[conversation] } != nil)
    }
  }

  /// tmux keeps a dead pane's last pid, which no longer names its program.
  @Test func aDeadClaudePaneDoesNotCount() throws {
    try withBusyConversation { service in
      setPanes(
        service, of: work, claude: PaneRow(pid: myPid, dead: true, clients: 0),
        shell: PaneRow(pid: unrelatedPane, dead: false, clients: 0))

      let error = end(service, caller: me)

      #expect(error?.contains("sb stop") == true, "\(error ?? "nil")")
    }
  }

  /// `Int32.max` passes `Processes.isValidPid` and names no process.
  @Test(arguments: [nil, 0, Int(Int32.max)] as [Int?]) func aCallerWhosePidCantBeReadIsRefused(_ pid: Int?) throws {
    try withBusyConversation { service in
      let error = end(service, caller: .client(pid: pid))

      let text = try #require(error)
      #expect(text.contains("can't tell"), Comment(rawValue: text))
      #expect(text.contains("`sb manager end`"), Comment(rawValue: text))
    }
  }

  /// sb sends `caller` from SB_SESSION_ID. An in-process caller has no ancestry, so only the `caller` check can
  /// refuse.
  @Test(arguments: [conversation, other, work, theOperator]) func aRequestThatNamesACallerIsRefused(_ id: String)
    throws
  {
    try withBusyConversation { service in
      let error = end(service, caller: .inProcess, ["caller": .string(id)])

      let text = try #require(error)
      #expect(!text.contains("sb stop"), Comment(rawValue: text))
    }
  }

  @Test func aCallerOutsideEveryPaneGetsPastTheChecks() throws {
    try withBusyConversation { service in
      setPanes(
        service, of: work, claude: PaneRow(pid: unrelatedPane, dead: false, clients: 0),
        shell: PaneRow(pid: unrelatedPane + 1, dead: false, clients: 0))

      let error = end(service, caller: me)

      #expect(error?.contains("sb stop") == true, "\(error ?? "nil")")
    }
  }

  // MARK: Resolving to-dos

  /// Gives the idle conversation open to-dos n1 and n2. An open to-do refuses every shape below before `remove`
  /// stops anything, so these tests run in-process without tmux.
  private func withOpenTodos(_ body: (Service) throws -> Void) throws {
    try withSessions { service in
      service.queue.sync {
        service.entries[conversation]?.session.notes = [
          Note(id: "n1", text: "tell Alex in #flags", by: .you, t: created, kind: .todo),
          Note(id: "n2", text: "bump the SDK", by: .you, t: created, kind: .todo),
        ]
      }
      try body(service)
    }
  }

  /// Requires that a refused request left the conversation, its open to-dos, and no drop allowance.
  private func expectKept(_ service: Service, sourceLocation: SourceLocation = #_sourceLocation) {
    let entry = service.queue.sync { service.entries[conversation] }
    #expect(entry != nil, sourceLocation: sourceLocation)
    #expect(entry?.session.openTodos.map(\.id) == ["n1", "n2"], sourceLocation: sourceLocation)
    #expect(service.queue.sync { service.endingDrops[conversation] } == nil, sourceLocation: sourceLocation)
  }

  /// A `resolve` and `by` shape that `rm` refuses before anything stops, and a phrase that the refusal contains.
  struct ResolveShape: Sendable, CustomTestStringConvertible {
    let label: String
    let args: [String: JSON]
    var says: String? = nil
    var testDescription: String { label }
  }

  static let refusedResolves: [ResolveShape] = [
    ResolveShape(label: "no resolve", args: [:]),
    ResolveShape(label: "a null resolve", args: ["resolve": .null]),
    ResolveShape(label: "an empty resolve", args: ["resolve": []]),
    ResolveShape(label: "a partial resolve", args: ["resolve": ["n1"]], says: "n2"),
    ResolveShape(label: "a stray id", args: ["resolve": ["n1", "n2", "n9"]], says: "n9 is not an open to-do"),
    ResolveShape(label: "only a stray id", args: ["resolve": ["n9"]]),
    ResolveShape(label: "a partial resolve by you", args: ["resolve": ["n2"], "by": "you"]),
    ResolveShape(
      label: "one to-do by claude", args: ["resolve": ["n1"], "by": "claude"], says: "Only you can resolve a to-do."),
    ResolveShape(
      label: "every to-do by claude", args: ["resolve": ["n1", "n2"], "by": "claude"],
      says: "Only you can resolve a to-do."),
    ResolveShape(label: "an empty resolve by claude", args: ["resolve": [], "by": "claude"]),
    ResolveShape(label: "an invalid by", args: ["resolve": ["n1", "n2"], "by": "robot"]),
    ResolveShape(label: "a string resolve", args: ["resolve": "n1"], says: "resolve is a list of note ids"),
    ResolveShape(label: "a number in resolve", args: ["resolve": [1]], says: "resolve is a list of note ids"),
    ResolveShape(label: "a mixed resolve", args: ["resolve": ["n1", 2]], says: "resolve is a list of note ids"),
    ResolveShape(label: "an object resolve", args: ["resolve": ["ids": ["n1"]]], says: "resolve is a list of note ids"),
    ResolveShape(label: "a bool resolve", args: ["resolve": .bool(true)], says: "resolve is a list of note ids"),
  ]

  /// `manager-end` forwards `resolve` and `by` to `rm`, so the two refuse each shape with the same message.
  @Test(arguments: refusedResolves)
  func managerEndRefusesEachResolveShapeAsRmDoes(_ shape: ResolveShape) throws {
    try withOpenTodos { service in
      let viaRm = refusal { _ = try service.remove(conversationArgs(shape.args), caller: .inProcess) }
      let viaEnd = end(service, caller: .inProcess, shape.args)

      let text = try #require(viaRm)
      #expect(viaEnd == text)
      if let says = shape.says {
        #expect(text.contains(says), Comment(rawValue: text))
      }
      expectKept(service)
    }
  }
}
