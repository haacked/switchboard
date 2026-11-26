import Foundation

/// A prompt that sbd sends to a session on an interval, or that sbd runs on its own in the session's folder: a
/// headless `claude -p` turn or a shell command. It lives in the session's row, so it survives restarts of sbd and of
/// claude.
///
/// An sbd built from an older commit decodes `Session.schedules` with that commit's types, and it refuses to load
/// any session when one row fails to decode. So a new raw value of an enum that `Session.schedules` stores breaks a
/// rollback. Put such a value under a new optional key, or in `Session.jobs`, which an older sbd ignores.
public struct Schedule: Codable, Equatable, Sendable {
  /// How a run reaches the session. A schedule stores nil for `session`, so its row reads the same to an older sbd.
  public enum Runner: String, Codable, Sendable {
    /// Sends the prompt into the session's claude.
    case session
    /// Runs the prompt as a one-shot `claude -p` turn in the session's folder.
    case headless
    /// Runs the prompt as a shell command in the session's folder.
    case script

    /// The runner that `text` names. Nil text means `session`.
    public init(parsing text: String?) throws {
      guard let text else {
        self = .session
        return
      }
      guard let runner = Runner(rawValue: text) else {
        throw APIError("a schedule runs as session, headless, or script, not \(text)")
      }
      self = runner
    }
  }

  /// The result of one run.
  public struct Run: Codable, Equatable, Sendable {
    /// `pasted`, `resumed`, and `queued` are the raw values of `Delivery`.
    public enum Outcome: String, Codable, Sendable {
      case pasted
      case resumed
      case queued
      case failed
      /// A headless or script run that exited with status 0. Only `Session.jobs` stores it.
      case ran

      public init(_ delivery: Delivery) {
        switch delivery {
        case .pasted: self = .pasted
        case .resumed: self = .resumed
        case .queued: self = .queued
        }
      }
    }

    /// Milliseconds since the epoch.
    public var t: Int64
    public var outcome: Outcome
    /// The due times that sbd dropped since the previous run.
    public var skipped: Int
    /// Set only for `failed`.
    public var error: String?
    /// The due times that the gate closed since the previous run. Nil when there were none.
    public var gated: Int?
    /// The id of the run's `sent` event. A failed run, and a run that sbd recorded before it stored this, has none.
    public var sent: Int64?
    /// The exit status of a headless or script run. Nil when the process ended on a signal or never started.
    public var exit: Int32?
    /// How long a headless or script run took, in ms.
    public var ms: Int64?
    /// The last line of a headless or script run's output that isn't blank.
    public var tail: String?

    public init(t: Int64, outcome: Outcome, skipped: Int, error: String? = nil, sent: Int64? = nil) {
      self.t = t
      self.outcome = outcome
      self.skipped = skipped
      self.error = error
      self.sent = sent
    }

    /// Such as `pasted 5m ago · 2 skipped · 3 gated`, `failed 2m ago: <error>`, or `ran 5m ago · exit 0 · <tail>`.
    public func text(now: Int64 = nowMs()) -> String {
      var text = outcomeText(now: now)
      if skipped > 0 { text += " · \(skipped) skipped" }
      if let gated, gated > 0 { text += " · \(gated) gated" }
      if let exit { text += " · exit \(exit)" }
      if let tail, !tail.isEmpty { text += " · \(tail)" }
      return text
    }

    /// Such as `pasted 5m ago` or `failed 2m ago: <error>`.
    public func outcomeText(now: Int64) -> String {
      "\(outcome.rawValue) \(ago(t, now: now)) ago\(error.map { ": \($0)" } ?? "")"
    }
  }

  /// Why sbd's `run-schedule` refuses the schedule.
  public enum RunBlocker: Equatable, Sendable {
    case paused
    /// The session's `hold`.
    case held(String)
  }

  public static let maxPerSession = 10
  public static let maxRuns = 10
  /// The most headless and script runs that sbd runs at once, across every session.
  public static let maxRunning = 2
  /// One minute, in ms.
  public static let minInterval: Int64 = 60_000
  /// The shortest and the longest timeout of a headless or script run, in ms.
  public static let timeouts: ClosedRange<Int64> = 10_000...7_200_000

  /// Unique across every session.
  public var id: String
  /// Sent verbatim, so a slash command runs as one.
  public var prompt: String
  /// The interval, in ms.
  public var every: Int64
  /// When the schedule is next due, in ms since the epoch. A time in the past
  /// means it waits for its session to be free.
  public var next: Int64
  /// Nil means active.
  public var paused: Bool?
  public var by: Author
  /// Milliseconds since the epoch.
  public var created: Int64
  /// Always equals `runs.first` once `record(_:)` wrote it.
  public var last: Run?
  /// The recent runs, newest first, at most `maxRuns`. Nil before the first
  /// recorded run and in a row stored before sbd kept the history.
  public var runs: [Run]?
  /// Nil for a schedule that sends its prompt on every due time.
  public var gate: Gate?
  /// Nil means `session`.
  public var runner: Runner?
  /// The Claude account of a headless run. Nil means the session's account.
  public var account: String?
  /// The model of a headless run. Nil means the model of the session's next launch.
  public var model: String?
  /// How long a headless or script run may take, in ms. Nil means the runner's default, which `runTimeout` gives.
  public var timeout: Int64?
  /// The start of the headless or script run in flight, in ms since the epoch. Nil when no run is in flight.
  public var running: Int64?

  public init(
    id: String, prompt: String, every: Int64, next: Int64, paused: Bool? = nil, by: Author, created: Int64,
    last: Run? = nil, runs: [Run]? = nil, gate: Gate? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.every = every
    self.next = next
    self.paused = paused
    self.by = by
    self.created = created
    self.last = last
    self.runs = runs
    self.gate = gate
  }

  /// How long a run may take, in ms: the stored timeout, or else 30m for a headless run and 10m for a script, cut to
  /// the interval, so a run ends before the next one is due.
  public var runTimeout: Int64 {
    timeout ?? Schedule.defaultTimeout(runner ?? .session, every: every)
  }

  /// The timeout of a run that has none of its own: 30m for a headless run and 10m for a script, cut to `every`.
  public static func defaultTimeout(_ runner: Runner, every: Int64) -> Int64 {
    min(runner == .headless ? 1_800_000 : 600_000, every)
  }

  /// The known runs, newest first. A row stored before sbd kept the history shows its `last`.
  public var history: [Run] { runs ?? last.map { [$0] } ?? [] }

  /// Saves the run as `last` and as the newest of `runs`, so the two can't
  /// drift. The run takes the gate's pending gated count, and the count resets.
  public mutating func record(_ run: Run) {
    var run = run
    if let pending = gate?.gated, pending > 0 { run.gated = pending }
    gate?.gated = nil
    // `history` falls back to `last`, so `runs` changes before `last` does.
    runs = Array(([run] + history).prefix(Schedule.maxRuns))
    last = run
  }

  /// How long a due schedule waits before it counts as overdue: one interval,
  /// but at least 10 minutes and at most an hour.
  public static func overdueGrace(_ every: Int64) -> Int64 { min(max(every, 600_000), 3_600_000) }

  /// The prompt without the spaces and newlines at its ends. A prompt with nothing else throws `refusal`.
  public static func cleanPrompt(_ text: String?, refusal: String = "a schedule needs a prompt") throws -> String {
    guard let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
      throw APIError(refusal)
    }
    return prompt
  }

  /// The schedule with a new interval, prompt, account, model, or timeout. A new interval
  /// moves the next run to one interval from now when that is sooner, and a
  /// paused schedule keeps its next run, because resume sets it. An empty
  /// account or model resets it to the session's. The runner never changes.
  public func edited(
    every: String?, prompt: String?, account: String? = nil, model: String? = nil, timeout: String? = nil,
    now: Int64
  ) throws -> Schedule {
    guard every != nil || prompt != nil || account != nil || model != nil || timeout != nil else {
      throw APIError("an edit needs every, an interval such as 30m, a prompt, an account, a model, or a timeout")
    }
    let runner = self.runner ?? .session
    if account != nil || model != nil, runner != .headless {
      throw APIError(Schedule.accountRefusal(runner))
    }
    if timeout != nil, runner == .session { throw APIError(Schedule.timeoutRefusal) }
    var edited = self
    if let every {
      let (ms, soonest) = try Schedule.interval(every, after: now)
      edited.every = ms
      if paused != true { edited.next = min(next, soonest) }
    }
    if let prompt { edited.prompt = try Schedule.cleanPrompt(prompt, runner: runner) }
    if let account { edited.account = account.isEmpty ? nil : try Schedule.cleanAccount(account) }
    if let model { edited.model = model.isEmpty ? nil : try Schedule.cleanModel(model) }
    if let timeout { edited.timeout = try Schedule.parseTimeout(timeout) }
    if let stored = edited.timeout, stored > edited.every {
      throw APIError(
        "the timeout \(Schedule.intervalText(stored)) is longer than the interval \(Schedule.intervalText(edited.every)). A run must end before the next one is due, so shorten the timeout or lengthen the interval"
      )
    }
    return edited
  }

  /// The prompt or command without the spaces and newlines at its ends. A script needs a command, and no run can
  /// carry a NUL character.
  public static func cleanPrompt(_ text: String?, runner: Runner) throws -> String {
    let prompt =
      runner == .script
      ? try cleanPrompt(text, refusal: "a script schedule needs a command") : try cleanPrompt(text)
    if runner != .session, prompt.hasNul { throw APIError("a schedule's prompt or command can't hold a NUL character") }
    return prompt
  }

  static func cleanAccount(_ account: String) throws -> String {
    let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !account.isEmpty, !account.hasNul else { throw APIError("the account needs a name, such as work") }
    return account
  }

  /// The model lands in claude's argv, so `Manager.modelProblem` checks it.
  static func cleanModel(_ model: String) throws -> String {
    if let problem = Manager.modelProblem(model) { throw APIError("model \(model): \(problem)") }
    if model.hasNul { throw APIError("the model name can't hold a NUL character") }
    return model
  }

  /// Reads one whole number and one unit, such as `10m`, and returns the timeout in ms. It refuses a timeout outside
  /// `timeouts`.
  public static func parseTimeout(_ text: String) throws -> Int64 {
    guard let ms = Wait.durationMs(text) else {
      throw APIError("can't read the timeout \(text). Write one number and one unit (s, m, or h), as 10m")
    }
    guard timeouts.contains(ms) else {
      throw APIError("a timeout is 10s to 2h, so \(text) is out of range")
    }
    return ms
  }

  static func accountRefusal(_ runner: Runner) -> String {
    runner == .script
      ? "a script runs no claude, so it takes no account or model"
      : "a schedule that sends its prompt into the session runs under the session's account and model. Add --headless to run it as its own claude -p turn"
  }

  static let timeoutRefusal =
    "a schedule that sends its prompt into the session has no timeout. Only a headless or script schedule takes one"

  /// The interval that `every` names, in ms, and the run one interval after `now`. Each error names `every`.
  static func interval(_ every: String, after now: Int64) throws -> (every: Int64, next: Int64) {
    do {
      let ms = try parseInterval(every)
      return (ms, try next(after: now, every: ms))
    } catch {
      throw APIError("every \(every): \(error)")
    }
  }

  /// Reads one whole number and one unit, `s`, `m`, `h`, `d`, or `w`, such as
  /// `30m`, and returns the interval in ms. It refuses an interval under
  /// `minInterval`.
  public static func parseInterval(_ text: String) throws -> Int64 {
    guard let ms = Wait.durationMs(text) else {
      if let total = compoundMs(text) {
        throw APIError("the interval \(text) has more than one unit. Write it with one, as \(intervalText(total))")
      }
      throw APIError("can't read the interval \(text). Write one number and one unit (s, m, h, d, or w), as 30m")
    }
    guard ms >= minInterval else { throw APIError("the shortest interval is 1m, so \(text) is too short") }
    return ms
  }

  /// The total of an interval such as `1h30m`, or nil for text that isn't
  /// two or more numbers that each have a unit.
  private static func compoundMs(_ text: String) -> Int64? {
    var parts: [Substring] = []
    var start = text.startIndex
    for i in text.indices where Wait.units[text[i]] != nil {
      parts.append(text[start...i])
      start = text.index(after: i)
    }
    guard parts.count > 1, start == text.endIndex else { return nil }
    var total: Int64 = 0
    for part in parts {
      guard let ms = Wait.durationMs(String(part)) else { return nil }
      let (sum, overflow) = total.addingReportingOverflow(ms)
      if overflow { return nil }
      total = sum
    }
    return total
  }

  /// An interval in the largest unit that divides it evenly, such as `30m`, `1h`, or `90s`.
  public static func intervalText(_ ms: Int64) -> String {
    let seconds = ms / 1000
    for (unit, size) in Wait.units.sorted(by: { $0.value > $1.value })
    where seconds % size == 0 && seconds >= size {
      return "\(seconds / size)\(unit)"
    }
    return "\(seconds)s"
  }

  /// The time one interval after `now`. It throws when that time is past the end of the clock.
  public static func next(after now: Int64, every: Int64) throws -> Int64 {
    let (next, overflow) = now.addingReportingOverflow(every)
    guard !overflow else { throw APIError("a run \(intervalText(every)) from now is past the end of the clock") }
    return next
  }

  public func isDue(now: Int64) -> Bool { paused != true && next <= now }

  /// The first reason that the session can't take the schedule's prompt now,
  /// or nil when it can. `process` is nil when sbd can't read the session's
  /// host. The card from `sb summary set` does not hold a schedule, as it
  /// does not hold a resolved `resume` wait.
  public static func blocker(facts: SessionFacts, process: PromptGuard.Process?, messageWaiting: Bool) -> String? {
    guard let process else { return "its host is not connected" }
    return PromptGuard.openCard(facts) ?? PromptGuard.turn(facts, process: process, messageWaiting: messageWaiting)
  }

  /// The reason that a session runs none of its schedules, or nil when it
  /// can run them. A removal job may be stopping the session's claude, so a
  /// session that the job holds waits too.
  public static func hold(done: Bool, paused: Bool, removing: Bool) -> String? {
    if done { return "the session is marked done" }
    if paused { return "the session is paused" }
    if removing { return "the session is being removed" }
    return nil
  }

  /// Why Run Now can't run the schedule, or nil when it can. `hold` is
  /// `Schedule.hold` for the schedule's session. The schedule's pause comes
  /// first, and a hold refuses even a schedule that isn't due.
  public func runBlocker(hold: String?) -> RunBlocker? {
    if paused == true { return .paused }
    return hold.map(RunBlocker.held)
  }

  /// The next run after a run at `now`, and the due times that the run
  /// drops. The next run counts from `now`, not from the old due time.
  public func fired(at now: Int64) -> (next: Int64, skipped: Int) {
    let next = (try? Schedule.next(after: now, every: every)) ?? .max
    return (next, Int(max(0, now - self.next) / every))
  }

  /// What runs, on one line: the prompt, `$ ` and a script's command, or `headless <model> on <account> · ` and the
  /// prompt. A headless schedule without its own model or account leaves that part out, because it runs on the
  /// session's. `sb schedule ls` and the app show it.
  public var whatText: String {
    switch runner ?? .session {
    case .session: oneLine(prompt)
    case .script: "$ \(oneLine(prompt))"
    case .headless:
      (["headless", model, account.map { "on \(Account.name(ofFolder: $0))" }].compactMap { $0 }
        .joined(separator: " ")) + " · \(oneLine(prompt))"
    }
  }

  /// The interval and the status text, such as `every 30m · next in 12m`. `sb schedule ls` and the app show it.
  public func timingText(_ status: String) -> String {
    "every \(Schedule.intervalText(every)) · \(status)"
  }

  /// When the schedule runs next, such as `next in 12m`, `paused`, or `due, runs when the session is free`.
  public func nextText(now: Int64 = nowMs()) -> String {
    if paused == true { return "paused" }
    if next <= now { return "due, runs when the session is free" }
    return "next \(fromNow(next, now: now))"
  }

  /// The result of the last run, such as `last: pasted 5m ago`, `last:
  /// failed 2m ago: <error>`, or `never ran`.
  public func lastText(now: Int64 = nowMs()) -> String {
    guard let last else { return "never ran" }
    return "last: \(last.text(now: now))"
  }

  /// Why the session can't take `schedule`, or nil when it can: an existing
  /// schedule of the same runner sends the same prompt or runs the same command, or tops up the same repository for
  /// the same group. A headless schedule is a duplicate only on the same account and model too. The text names the
  /// existing schedule.
  public static func duplicate(of schedule: Schedule, in existing: [Schedule]) -> String? {
    let prompt = schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    for other in existing where other.id != schedule.id {
      if (other.runner ?? .session) == (schedule.runner ?? .session), other.account == schedule.account,
        other.model == schedule.model,
        other.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
      {
        let does =
          switch schedule.runner ?? .session {
          case .session: "sends this prompt to the session"
          case .headless: "runs this prompt headless on the same account and model"
          case .script: "runs this command"
          }
        return "schedule \(other.id) already \(does). Edit it or remove it with: sb schedule rm \(other.id)"
      }
      if let gate = schedule.gate, let otherGate = other.gate, gate.group == otherGate.group,
        Dependencies.sameRepo(gate.repo, otherGate.repo)
      {
        return
          "schedule \(other.id) already tops up \(otherGate.repo) for this group on the session. Edit it or remove it with: sb schedule rm \(other.id)"
      }
    }
    return nil
  }
}

extension Session {
  /// Why sbd's tick runs none of the session's schedules, or nil.
  public var scheduleHold: String? {
    Schedule.hold(done: done, paused: Pause.blocker(self) != nil, removing: removal?.holdsSession == true)
  }

  /// Every schedule of the session: the ones that send their prompt into the session, then the headless and script
  /// ones. Code reads and changes the session's schedules only through these accessors, so only they know that
  /// `jobs` holds the headless and script schedules.
  public var allSchedules: [Schedule] { (schedules ?? []) + (jobs ?? []) }

  public func schedule(_ id: String) -> Schedule? {
    allSchedules.first { $0.id == id }
  }

  /// A schedule with a runner goes to `jobs`, because an older sbd would decode it in `schedules` as a prompt to send.
  public mutating func addSchedule(_ schedule: Schedule) {
    if (schedule.runner ?? .session) == .session {
      schedules = (schedules ?? []) + [schedule]
    } else {
      jobs = (jobs ?? []) + [schedule]
    }
  }

  /// It changes nothing when the session has no schedule with the id. The change keeps the schedule's runner, so
  /// a schedule never moves between `schedules` and `jobs`.
  public mutating func changeSchedule(_ id: String, _ change: (inout Schedule) -> Void) {
    func changed(_ list: [Schedule]?) -> [Schedule]? {
      list?.map { schedule in
        var schedule = schedule
        if schedule.id == id {
          let runner = schedule.runner
          change(&schedule)
          schedule.runner = runner
        }
        return schedule
      }
    }
    schedules = changed(schedules)
    jobs = changed(jobs)
  }

  /// A session with no schedule left in an array stores nil there, so its row matches one that never had one.
  public mutating func removeSchedule(_ id: String) {
    func rest(_ list: [Schedule]?) -> [Schedule]? {
      let rest = (list ?? []).filter { $0.id != id }
      return rest.isEmpty ? nil : rest
    }
    schedules = rest(schedules)
    jobs = rest(jobs)
  }
}

extension SessionSummary {
  /// `Schedule.hold` from the facts that `Service.summary` copies from the session, so it matches sbd's tick.
  public var scheduleHold: String? {
    Schedule.hold(done: markedDone, paused: pause != nil, removing: isBeingRemoved)
  }

  public var allSchedules: [Schedule] { schedules ?? [] }
}

/// The arguments of the `schedule` request, as sb sends them.
public struct ScheduleRequest: Codable, Equatable, Sendable {
  /// An interval such as `30m`.
  public var every: String?
  public var prompt: String?
  /// `you` or `claude`. Nil means you.
  public var by: String?
  /// Named `gate`, not `group`, so it can't collide with the scope field `group` that a scoped MCP server sends.
  public var gate: Gate?
  /// `session`, `headless`, or `script`. Nil means `session`. A script's command travels in `prompt`.
  public var runner: String?
  /// A headless schedule's Claude account. On an edit, an empty value resets it to the session's.
  public var account: String?
  /// A headless schedule's model. On an edit, an empty value resets it to the session's.
  public var model: String?
  /// A headless or script run's timeout, such as `10m`.
  public var timeout: String?

  /// The top-up gate as sb sends it. `group` is the group's id or name, which sbd resolves.
  public struct Gate: Codable, Equatable, Sendable {
    public var group: String?
    /// owner/name
    public var repo: String?
    public var target: Int?
    public var template: String?
    public var rubric: String?

    public init(group: String?, repo: String?, target: Int?, template: String?, rubric: String?) {
      self.group = group
      self.repo = repo
      self.target = target
      self.template = template
      self.rubric = rubric
    }

    /// The checked gate in `group`, the id that sbd resolved from the request's `group`.
    func make(group: String) throws -> Schedule.Gate {
      guard let repo, Issues.validRepo(repo) else {
        throw APIError("a top-up needs a repository as owner/name, not \(repo ?? "nothing")")
      }
      guard let target, Schedule.Gate.targets.contains(target) else {
        throw APIError("a top-up's target is 1 to 20 sessions, not \(target.map(String.init) ?? "nothing")")
      }
      let template = try Schedule.cleanPrompt(template, refusal: "a top-up needs a template")
      let rubric = try Schedule.cleanPrompt(rubric, refusal: "a top-up needs a rubric")
      return Schedule.Gate(group: group, repo: repo, target: target, template: template, rubric: rubric)
    }
  }

  public init(
    every: String?, prompt: String?, by: String?, gate: Gate? = nil, runner: String? = nil, account: String? = nil,
    model: String? = nil, timeout: String? = nil
  ) {
    self.every = every
    self.prompt = prompt
    self.by = by
    self.gate = gate
    self.runner = runner
    self.account = account
    self.model = model
    self.timeout = timeout
  }

  /// Checks the arguments and builds a schedule whose first run is one
  /// interval after `now`. A request with a gate needs `group`, the group
  /// that sbd resolved from the gate's `group`, and gets the default prompt
  /// when it has none. Only a headless schedule takes an account and a model,
  /// only a headless or script schedule takes a timeout, and only a schedule
  /// that sends its prompt into the session takes a gate.
  public func makeSchedule(id: String, now: Int64, group: (id: String, name: String)? = nil) throws -> Schedule {
    let runner = try Schedule.Runner(parsing: runner)
    if runner != .session {
      return try makeDetached(id: id, runner: runner, now: now)
    }
    if account != nil || model != nil { throw APIError(Schedule.accountRefusal(runner)) }
    if timeout != nil { throw APIError(Schedule.timeoutRefusal) }
    if gate != nil && group == nil { throw APIError("a top-up needs a group") }
    guard let every else { throw APIError("a schedule needs every, an interval such as 30m") }
    let (ms, next) = try Schedule.interval(every, after: now)
    guard let request = gate, let group else {
      return Schedule(
        id: id, prompt: try Schedule.cleanPrompt(prompt), every: ms, next: next, by: try Author(parsing: by),
        created: now)
    }
    let gate = try request.make(group: group.id)
    let prompt =
      (try? Schedule.cleanPrompt(prompt))
      ?? Schedule.Gate.defaultPrompt(groupName: group.name, repo: gate.repo, target: gate.target)
    return Schedule(
      id: id, prompt: prompt, every: ms, next: next, by: try Author(parsing: by), created: now, gate: gate)
  }

  /// A headless or script schedule. `edited` checks the timeout, so an add and an edit refuse the same timeouts.
  private func makeDetached(id: String, runner: Schedule.Runner, now: Int64) throws -> Schedule {
    if gate != nil {
      throw APIError("a top-up sends its prompt into the session, so it can't run headless or as a script")
    }
    if runner == .script, account != nil || model != nil { throw APIError(Schedule.accountRefusal(runner)) }
    guard let every else { throw APIError("a schedule needs every, an interval such as 30m") }
    let (ms, next) = try Schedule.interval(every, after: now)
    var schedule = Schedule(
      id: id, prompt: try Schedule.cleanPrompt(prompt, runner: runner), every: ms, next: next,
      by: try Author(parsing: by), created: now)
    schedule.runner = runner
    if let account { schedule.account = try Schedule.cleanAccount(account) }
    if let model { schedule.model = try Schedule.cleanModel(model) }
    if let timeout {
      schedule = try schedule.edited(every: nil, prompt: nil, timeout: timeout, now: now)
    }
    return schedule
  }
}

/// A schedule with its session, as the schedule requests return it.
public struct ScheduleRow: Codable, Equatable, Sendable {
  public var session: String
  public var name: String
  public var schedule: Schedule
  /// Computed when sbd answers, never stored. Nil from an sbd older than the status.
  public var status: ScheduleStatus?

  public init(session: String, name: String, schedule: Schedule, status: ScheduleStatus? = nil) {
    self.session = session
    self.name = name
    self.schedule = schedule
    self.status = status
  }
}

/// Whether a schedule runs, waits, or needs the user, with a line that says so.
public struct ScheduleStatus: Codable, Equatable, Sendable {
  /// Agents read these raw values in `sb schedule ls --json`.
  public enum State: String, Codable, Sendable {
    case active
    case due
    case overdue
    case failed
    case held
    case paused

    fileprivate var rank: Int {
      switch self {
      case .failed: 0
      case .overdue: 1
      case .due: 2
      case .active: 3
      case .held: 4
      case .paused: 5
      }
    }
  }

  public var state: State
  public var text: String

  /// `hold` is `Schedule.hold` for the schedule's session, the reason that
  /// sbd's tick runs none of the session's schedules. The first rule that
  /// matches wins: paused, failed, active, held, overdue, then due.
  public init(_ schedule: Schedule, hold: String?, now: Int64) {
    if schedule.paused == true {
      state = .paused
      text = "paused"
      return
    }
    let (state, text) = ScheduleStatus.timing(schedule, hold: hold, now: now)
    if let last = schedule.last, last.outcome == .failed {
      self.state = .failed
      self.text = "\(last.outcomeText(now: now)) · \(text)"
    } else {
      self.state = state
      self.text = text
    }
  }

  public var needsAttention: Bool { state == .failed || state == .overdue }

  /// The Loops tab's order: failed, overdue, due, active, held, then paused,
  /// then by the next run, then by id.
  public static func attentionOrder(
    _ a: (status: ScheduleStatus, schedule: Schedule), _ b: (status: ScheduleStatus, schedule: Schedule)
  ) -> Bool {
    (a.status.state.rank, a.schedule.next, a.schedule.id) < (b.status.state.rank, b.schedule.next, b.schedule.id)
  }

  /// The state and text of a schedule that isn't paused, from its next run and its session's hold.
  private static func timing(_ schedule: Schedule, hold: String?, now: Int64) -> (State, String) {
    if schedule.next > now { return (.active, "next \(fromNow(schedule.next, now: now))") }
    if let hold { return (.held, "held: \(hold)") }
    if now - schedule.next >= Schedule.overdueGrace(schedule.every) {
      return (.overdue, "overdue by \(ago(schedule.next, now: now)), runs when the session is free")
    }
    return (.due, "due \(ago(schedule.next, now: now)) ago, runs when the session is free")
  }
}
