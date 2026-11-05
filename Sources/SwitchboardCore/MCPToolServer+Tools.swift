import Foundation

extension MCPToolServer {
  struct Tool: Sendable {
    let name: String
    let description: String
    let properties: [String: JSON]
    let required: [String]

    init(_ name: String, _ description: String, _ properties: [String: JSON] = [:], required: [String] = []) {
      self.name = name
      self.description = description
      self.properties = properties
      self.required = required
    }

    var json: JSON {
      [
        "name": .string(name),
        "description": .string("\(description) \(MCPToolServer.dataRule)"),
        "inputSchema": [
          "type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string)),
        ],
      ]
    }
  }

  private static func property(_ type: String, _ description: String) -> JSON {
    ["type": .string(type), "description": .string(description)]
  }
  private static func string(_ description: String) -> JSON { property("string", description) }
  private static func integer(_ description: String) -> JSON { property("integer", description) }
  private static func boolean(_ description: String) -> JSON { property("boolean", description) }
  private static func strings(_ description: String) -> JSON {
    ["type": "array", "items": ["type": "string"], "description": .string(description)]
  }

  private static let session = string("A session: an id, a unique id prefix, or a unique name.")
  private static let group = string("A group: an id, a unique id prefix, or a unique name.")

  static let allTools: [Tool] = [
    Tool(
      "list_sessions",
      "Lists the sessions with their state, reason, PR, waits, and notes. The sessions that need the user come first."),
    Tool(
      "get_session", "Shows one session, with its group's name and description.", ["session": session],
      required: ["session"]),
    Tool(
      "read_reply", "Reads the session's last reply from its transcript, as Markdown.", ["session": session],
      required: ["session"]),
    Tool(
      "triage",
      "Lists the sessions that need the user or that Claude can continue, in the order to handle them. Each has a title, a summary, and options."
    ),
    Tool(
      "events",
      "Lists events from sessions. Without `since`, it lists the newest events. With `since`, it lists the events after that id.",
      [
        "since": integer("An event id. The answer lists the events after it."),
        "session": session,
        "limit": integer("The maximum number of events to list. Default \(Event.defaultLimit)."),
      ]),
    Tool(
      "send",
      "Sends a message to one session. Depending on the session's state, it pastes the message, queues it, or resumes the session with it.",
      ["session": session, "text": string("The message.")], required: ["session", "text"]),
    Tool(
      "send_group",
      "Asks to send a message to every session in a group except the calling session. It sends nothing itself. Switchboard shows the user the message and its targets, and the user sends or cancels it there. The answer has a `pending` id. Call again with only `pending` to wait up to `timeout` seconds for the decision. The decision is pending, sent, cancelled, or expired. Pending means the user has not decided yet, and the other three are final. A call with the same text opens a second request.",
      [
        "group": group, "text": string("The message."),
        "pending": integer(
          "The id from an earlier send_group answer. Pass it without text to wait for that request's decision."),
        "timeout": integer(
          "The number of seconds to wait for the decision when `pending` is set. Default 30, at most \(MCPToolServer.maxPendingWait)."
        ),
      ]),
    Tool(
      "spawn",
      "Starts a session on a new branch in a new worktree of a repository, or with `followup` adds it as a follow-up that has not started. The calling session becomes its parent. The prompt is the new session's whole brief, so make it self-contained.",
      [
        "repository": string("The repository: owner/name, a bare name, or the path of a checkout."),
        "branch": string("The new branch."),
        "prompt": string("The first prompt."),
        "base": string("The commit that the branch starts from, such as origin/main. A follow-up takes none."),
        "name": string("The session's name."),
        "model": string("The model to run, such as sonnet or opus."),
        "account": string("The Claude account, by name or folder."),
        "followup": boolean("Adds a follow-up instead of starting the session."),
        "after": string("For a follow-up, a PR such as pr:123 whose merge moves it to Needs you."),
      ], required: ["repository", "branch", "prompt"]),
    Tool(
      "set_wait",
      "Sets a wait on a session, by default the calling session. The kinds ci, review, bot-review, approval, queue, merge, and deploy wait on a PR. Pass it as `target`, or leave `target` out to use the session's own PR. review needs `who`. deploy needs `environment`. session waits on another session, given as `target`, until it reaches `state` (default done). date waits until `until`. manual, the default, waits on something outside Switchboard, which `note` describes.",
      [
        "session": session,
        "kind": string(
          "manual, ci, review, bot-review, approval, queue, merge, deploy, session, or date. Default manual."),
        "target": string("A PR (owner/name#N or a URL), or for kind session another session."),
        "who": string("The reviewer, for kind review."),
        "environment": string("dev, prod-us, prod-eu, or prod, for kind deploy."),
        "service": string("The service, for kind deploy."),
        "state": string("The state to wait for, for kind session. Default done."),
        "until": string("A duration such as 2h, or a date or time such as 2026-10-26 or 2026-10-26T09:00."),
        "note": string("What the wait is for."),
        "then": string(
          "What happens when the wait ends: resume the session (the default), or notify, which moves it to Needs you."),
      ]),
    Tool(
      "clear_wait",
      "Clears all of a session's waits, by default the calling session's, or only the wait that `wait` names.",
      ["session": session, "wait": string("The id of one wait.")]),
    Tool(
      "add_note", "Adds a note to a session.", ["session": session, "text": string("The note.")],
      required: ["session", "text"]),
    Tool(
      "list_groups", "Lists the groups with their descriptions, sessions, and notes, then the sessions in no group."),
    Tool(
      "add_group", "Adds a group.",
      [
        "name": string("The group's name."), "sessions": strings("The sessions to move into it."),
        "note": string("A note."),
      ], required: ["name"]),
    Tool("remove_group", "Removes a group. Its sessions become ungrouped.", ["group": group], required: ["group"]),
    Tool(
      "move_to_group", "Moves sessions into a group, or into no group with `ungrouped`.",
      [
        "sessions": strings("The sessions."), "group": group,
        "ungrouped": boolean("Moves the sessions into no group."),
      ], required: ["sessions"]),
    Tool(
      "add_group_note", "Adds a note to a group.", ["group": group, "text": string("The note.")],
      required: ["text"]),
    Tool(
      "suggest_groups",
      "Lists groups suggested from branch names and PR titles. With `accept`, it accepts that suggestion instead.",
      ["accept": string("The id of a suggestion to accept.")]),
    Tool(
      "plan_artifact",
      "Reports the result of one `Switchboard plan artifact task.` step to Switchboard. Use kind `read` after a read task, `proposal` after a rewrite task, and `check` then `published` in a publish task. If it answers with an error, stop and do not publish.",
      [
        "plan": string("The plan id from the message's `plan:` line."),
        "kind": string("One of read, proposal, check, or published."),
        "file": string(
          "The path of a file that holds the full text: the artifact's text for read and check, the rewritten file for proposal."
        ),
        "text": string("The same text, when you did not save it to a file. Send file or text, not both."),
        "version": string("The version or update time that the Artifact tool showed, if any."),
      ], required: ["plan", "kind"]),
  ]
}
