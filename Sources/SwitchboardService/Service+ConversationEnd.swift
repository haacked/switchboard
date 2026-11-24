import Foundation
import SwitchboardCore

/// Ending a Manager conversation, and the context size that suggests it.
/// `plans/end-manager-conversation.md` in the notes repo describes it.
extension Service {
  /// A serial queue keeps the reads in the order of their turns, so an older turn's slow read can't replace a newer
  /// turn's value.
  static let contextReads = DispatchQueue(label: "sbd.context")

  /// Reads the conversation's context size from its transcript off the state queue, then records a `context` event
  /// when the value changed. A read that finishes after a `/clear`, a compaction, a resume of another conversation,
  /// or the conversation's removal records nothing.
  func recordContext(_ id: String) {
    guard let e = entries[id] else { return }
    let findTranscript = transcriptFinder(id)
    let machine = site(for: e.session).machine
    let claudeSessionId = e.session.claudeSessionId
    let lastStart = e.facts.lastStart
    Self.contextReads.async { [self] in
      let tokens = findTranscript().flatMap { Transcript.contextTokens($0, on: machine) }
      queue.async { [self] in
        guard let now = entries[id], now.session.claudeSessionId == claudeSessionId,
          now.facts.lastStart == lastStart, now.facts.contextTokens != tokens
        else { return }
        record(id, "context", ["tokens": tokens.map { .number(Double($0)) } ?? .null])
      }
    }
  }

  // MARK: The end hint

  /// The conversation's end hint. Its spawned sessions are those that its events recorded and those whose parent it
  /// is, which includes a follow-up that it captured. It runs on the state queue.
  func endHint(_ e: Entry, _ facts: SessionFacts) -> EndHint? {
    let id = e.session.id
    let ids = facts.spawned.union(entries.filter { $0.value.session.parent == id }.keys)
    // A session that sbd holds but never tracked is not gone.
    let spawned = Dictionary(
      uniqueKeysWithValues: ids.map { child in (child, entries[child].map { $0.facts.lastState ?? .notStarted }) })
    let openPrompt = facts.openPermission != nil || facts.openQuestion != nil
    return EndHint.evaluate(
      spawned: spawned, hasOwnItems: !e.session.ownItems.isEmpty, inTurnOrJob: facts.inTurnOrJob,
      messageOnItsWay: e.hasMessageOnItsWay,
      needsMe: ChatMark.needsMe(cards: facts.cards, openPrompt: openPrompt), contextTokens: facts.contextTokens,
      threshold: config.conversationHintTokens, dismissed: facts.endHintDismissed)
  }

  /// The `manager-hint` request, which answers the summary of the Manager conversation that `session` names. With
  /// `dismiss`, it first records the key of the hint that shows, which hides the hint until its key changes. Only the
  /// user dismisses a hint, so it refuses a dismissal that names a `caller`. It runs on the state queue.
  func managerHint(_ args: JSON) throws -> JSON {
    let dismiss = args["dismiss"]?.bool == true
    if dismiss, let caller = args["caller"]?.string {
      let name = entries[caller]?.session.name ?? caller
      throw APIError("\(name) can't dismiss a conversation's end hint. Only the user dismisses it")
    }
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let id = try managerConversation(ref)
    if dismiss, let key = endHint(entries[id]!, shownFacts(id, for: .mac))?.key {
      record(id, "end-hint-dismissed", ["key": .string(key)])
    }
    return try JSON(encoding: summary(id))
  }

  // MARK: Ending

  static let endCommand = "sb manager end"

  /// Refuses to remove a Manager conversation while a message is queued for it or claude has not confirmed one,
  /// whatever its pause state, because no id names a message and the removal would drop it unseen. It also
  /// refuses while its own waits, its pause condition, or its schedules hold an id that `endingDrops[id]` does
  /// not name. A wait handed to the operator sits on the operator, so it never blocks. `removalEntry` and
  /// `forgetSession` both call it, because a wait, a pause, or a message can land while the panes stop. It runs
  /// on the state queue.
  func refuseConversationRemoval(_ id: String) throws {
    guard let e = entries[id], e.session.kind == .manager else { return }
    let session = e.session
    if e.hasMessageOnItsWay { throw messagesRefusal(e) }
    let drops = endingDrops[id] ?? []
    let own = session.ownItems
    let unnamed = own.filter { !drops.contains($0.id) }.map { "  \($0.id)  \($0.line)" }
    guard !unnamed.isEmpty else { return }
    let flags = own.map { "--drop \($0.id)" }.joined(separator: " ")
    throw APIError(
      "\(session.name) has waits or schedules of its own that removing it would drop:\n"
        + unnamed.joined(separator: "\n")
        + "\nTo end it and drop them, run: \(Self.endCommand) \(id) \(flags)")
  }

  /// The refusal for a conversation that holds messages, with the step that delivers them in its state.
  private func messagesRefusal(_ e: Entry) -> APIError {
    let id = e.session.id
    let lines =
      e.pending.map { "  \(oneLine($0.text))" }
      + (e.inFlight == nil ? [] : ["  a message that claude has not confirmed yet"])
    let count = lines.count
    let remedy =
      if e.session.pause != nil {
        "Resume it to deliver them first, with: sb resume \(id)"
      } else if claudeState(id) == .stopped {
        "Start it to deliver them first, with: sb open \(id)"
      } else {
        "They reach claude once it is ready for them. Try again then."
      }
    return APIError(
      "\(e.session.name) has \(count == 1 ? "1 message on its" : "\(count) messages on their") way to it "
        + "that removing it would drop:\n"
        + lines.joined(separator: "\n") + "\n" + remedy)
  }

  /// The `manager-end` request, which removes a Manager conversation, and with `new` starts one in its place
  /// with the same account, MCP servers, and pin. `drop` names the conversation's own waits, pause condition, and
  /// schedules that the removal may drop. `resolve` and `by` pass to `rm`, which resolves the named to-dos under the
  /// same rules as a delete of a work session. Only the user ends a conversation, so it refuses a request that names a
  /// `caller` and a client below any local session's live pane. It also refuses a client below sbd's tmux
  /// server that runs outside every pane. It runs off the state queue, because `remove` does.
  func managerEnd(_ args: JSON, caller: Caller) throws -> JSON {
    if let from = args["caller"]?.string {
      let name = queue.sync { entries[from]?.session.name } ?? from
      throw APIError(
        "\(name) can't end a Manager conversation. Only the user ends one, from a terminal outside every session.")
    }
    let ancestry = try caller.ancestry(command: Self.endCommand)
    guard let ref = args["session"]?.string, !ref.isEmpty else { throw APIError("name a Manager conversation") }
    let drops = Set(args["drop"]?.array?.compactMap(\.string) ?? [])
    // A pane that started after the last tick is in no older snapshot.
    let fresh = ancestry == nil ? nil : buildSnapshot()
    let ending = try queue.sync { () -> Ending in
      install(fresh)
      if let ancestry {
        // A shell pane counts, because a session's Claude can type into its own shell pane with `tmux send-keys`.
        let place = callerPlace(ancestry)
        if let pane = place.inside.first {
          throw APIError(
            "`\(Self.endCommand)` runs inside a pane of \(mention(pane)). "
              + "Only the user ends a conversation. Run it from a terminal outside the session.")
        }
        // A program that a session starts with `tmux new-session` or `tmux new-window` runs below the server and
        // outside every pane.
        if place.inServer {
          throw APIError(
            "`\(Self.endCommand)` runs in sbd's tmux server, where the sessions run. "
              + "Only the user ends a conversation. Run it from a terminal outside the sessions.")
        }
      }
      let id = try managerConversation(ref)
      let e = entries[id]!
      if e.facts.inTurnOrJob {
        throw APIError(
          "\(e.session.name) is in a turn or runs a background job. Wait for it to finish, or stop it with: sb stop \(id)"
        )
      }
      if let refusal = beingDeletedRefusal(id) { throw refusal }
      if endingDrops[id] != nil { throw APIError("\(mention(id)) is being deleted") }
      endingDrops[id] = drops
      return Ending(
        session: e.session, findTranscript: transcriptFinder(id),
        dropped: e.session.ownItems.map(\.id).filter(drops.contains))
    }
    let session = ending.session
    defer { queue.sync { endingDrops[session.id] = nil } }
    let transcript = ending.findTranscript()
    var removal: [String: JSON] = ["session": .string(session.id)]
    for key in ["resolve", "by"] { removal[key] = args[key] }
    _ = try remove(.object(removal), caller: caller)
    var answer: [String: JSON] = [
      "ended": .string(session.id), "name": .string(session.name), "transcript": transcript.map(JSON.string) ?? .null,
      "claudeSessionId": .string(session.claudeSessionId),
      "handed": .array(queue.sync { handedOff(from: session.id)?.waits ?? [] }.map { .string($0.id) }),
      "dropped": .array(ending.dropped.map(JSON.string)),
    ]
    if args["new"]?.bool == true {
      do {
        answer["started"] = try JSON(encoding: startInPlace(of: session, name: args["name"]?.string))
      } catch {
        throw APIError(
          "Ended \(session.name), whose transcript is at \(transcript ?? "an unknown path"), "
            + "but can't start a new conversation: \(error)")
      }
    }
    return .object(answer)
  }

  /// What `managerEnd` reads on the state queue before the removal.
  struct Ending {
    var session: Session
    var findTranscript: () -> String?
    /// The ids of the conversation's own waits, pause condition, and schedules that `drop` names.
    var dropped: [String]
  }

  /// Starts an untitled conversation, or one named `name`, with the account, MCP servers, and pin of `ended`.
  /// It runs off the state queue.
  private func startInPlace(of ended: Session, name: String?) throws -> SessionSummary {
    try ensureManagerFolder()
    awaitMCPServers()
    return try queue.sync {
      let id = try createManager(
        name: name.flatMap { $0.isEmpty ? nil : $0 }, prompt: nil, account: ended.claudeConfigDir, mcp: ended.mcp
      ).id
      if ended.pinned == true {
        try update(id) { $0.pinned = true }
        record(id, "pinned")
      }
      return summary(id)
    }
  }
}
