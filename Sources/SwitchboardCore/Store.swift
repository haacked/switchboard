import Foundation
import SQLite3

/// sbd's SQLite database: the sessions and their event log. Each session is a
/// JSON row, so a new field needs no table migration.
public final class Store {
  private var db: OpaquePointer?

  public init(path: String) throws {
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw APIError("can't open \(path): \(String(cString: sqlite3_errmsg(db)))")
    }
    try exec("PRAGMA journal_mode = WAL")
    try exec("PRAGMA busy_timeout = 2000")
    try exec("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    try exec(
      "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, t INTEGER NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL)"
    )
    try exec("CREATE INDEX IF NOT EXISTS events_session ON events (session, id)")
    try exec("CREATE TABLE IF NOT EXISTS followup_imports (line TEXT PRIMARY KEY)")
    try exec("CREATE TABLE IF NOT EXISTS claude_sessions (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    try exec("CREATE TABLE IF NOT EXISTS snapshots (session TEXT PRIMARY KEY, json TEXT NOT NULL)")
    try exec("CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    try exec("CREATE TABLE IF NOT EXISTS plans (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    try exec("CREATE TABLE IF NOT EXISTS declined_suggestions (id TEXT PRIMARY KEY)")
    try exec(
      "CREATE TABLE IF NOT EXISTS resolved_todos (id INTEGER PRIMARY KEY, session TEXT, name TEXT, repo TEXT, branch TEXT, pr INTEGER, note TEXT, text TEXT, by TEXT, added INTEGER, resolved INTEGER, how TEXT)"
    )
    try exec("CREATE TABLE IF NOT EXISTS host_events (id TEXT PRIMARY KEY, host TEXT, session TEXT)")
    try exec(
      "CREATE TABLE IF NOT EXISTS removed_host_sessions (id TEXT NOT NULL, host TEXT NOT NULL, PRIMARY KEY (id, host))")
  }

  deinit { sqlite3_close(db) }

  public func save(_ session: Session) throws {
    try run("INSERT OR REPLACE INTO sessions (id, json) VALUES (?, ?)", [session.id, try JSONCoding.encode(session)])
  }

  /// Deletes the session's record, events, and snapshot, and records the
  /// resolved to-dos, in one transaction. A failure leaves all of it as it was.
  /// For a session on `host`, the same transaction records it in
  /// `removed_host_sessions`.
  public func delete(session id: String, resolving todos: [ResolvedTodo] = [], onHost host: String? = nil) throws {
    try transaction { try deleteRows(session: id, resolving: todos, onHost: host) }
  }

  /// Throws when `delete(session:resolving:onHost:)` hits an abort or a constraint, a
  /// read-only connection, or a write lock held past the busy timeout. It runs
  /// the same statements in a transaction that it rolls back. It does not see
  /// a failure that only the commit causes.
  public func checkDeletable(session id: String, resolving todos: [ResolvedTodo], onHost host: String? = nil) throws {
    try exec("BEGIN IMMEDIATE")
    defer { try? exec("ROLLBACK") }
    try deleteRows(session: id, resolving: todos, onHost: host)
  }

  private func deleteRows(session id: String, resolving todos: [ResolvedTodo], onHost host: String?) throws {
    for todo in todos { try insert(todo) }
    try run("DELETE FROM sessions WHERE id = ?", [id])
    try run("DELETE FROM events WHERE session = ?", [id])
    try run("DELETE FROM snapshots WHERE session = ?", [id])
    if let host { try recordRemovedHostSession(id, host: host) }
  }

  /// Saves the session and records the resolved to-do, in one transaction.
  public func save(_ session: Session, resolving todo: ResolvedTodo) throws {
    try transaction {
      try insert(todo)
      try save(session)
    }
  }

  private func insert(_ todo: ResolvedTodo) throws {
    try run(
      "INSERT INTO resolved_todos (session, name, repo, branch, pr, note, text, by, added, resolved, how) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        todo.session, todo.name, todo.repo as Any, todo.branch as Any, todo.pr as Any, todo.note, todo.text,
        todo.by.rawValue, todo.added, todo.resolved, todo.how,
      ])
  }

  /// The resolved to-dos, newest first.
  public func resolvedTodos(limit: Int) throws -> [ResolvedTodo] {
    try query(
      "SELECT id, session, name, repo, branch, pr, note, text, by, added, resolved, how FROM resolved_todos ORDER BY id DESC LIMIT ?",
      [limit]
    ) { row in
      ResolvedTodo(
        id: row.int(0), session: row.text(1), name: row.text(2), repo: row.optionalText(3),
        branch: row.optionalText(4), pr: row.optionalInt(5), note: row.text(6), text: row.text(7),
        by: Author(rawValue: row.text(8)) ?? .you, added: row.int(9), resolved: row.int(10), how: row.text(11))
    }
  }

  /// The snapshot that `Snapshots` saved for the session, as JSON text.
  public func snapshot(session id: String) throws -> String? {
    try query("SELECT json FROM snapshots WHERE session = ?", [id]) { $0.text(0) }.first
  }

  public func save(snapshot json: String, session id: String) throws {
    // A saver that finishes after the session's removal must not leave a row.
    try run(
      "INSERT OR REPLACE INTO snapshots (session, json) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM sessions WHERE id = ?)",
      [id, json, id])
  }

  /// Removes the snapshots of sessions that no longer exist.
  public func pruneSnapshots() throws {
    try exec("DELETE FROM snapshots WHERE session NOT IN (SELECT id FROM sessions)")
  }

  public func hasEvent(_ id: Int64, session: String) throws -> Bool {
    !(try query("SELECT 1 FROM events WHERE id = ? AND session = ?", [id, session]) { $0.int(0) }).isEmpty
  }

  public func sessions() throws -> [Session] {
    try query("SELECT json FROM sessions ORDER BY id", []) { row in
      try JSONCoding.decode(Session.self, from: row.text(0))
    }
  }

  public func save(group: SessionGroup) throws {
    try run("INSERT OR REPLACE INTO groups (id, json) VALUES (?, ?)", [group.id, try JSONCoding.encode(group)])
  }

  public func delete(group id: String) throws {
    try run("DELETE FROM groups WHERE id = ?", [id])
  }

  public func groups() throws -> [SessionGroup] {
    try query("SELECT json FROM groups ORDER BY id", []) { row in
      try JSONCoding.decode(SessionGroup.self, from: row.text(0))
    }
  }

  public func save(plan: PlanDocument) throws {
    try run("INSERT OR REPLACE INTO plans (id, json) VALUES (?, ?)", [plan.id, try JSONCoding.encode(plan)])
  }

  public func delete(plan id: String) throws {
    try run("DELETE FROM plans WHERE id = ?", [id])
  }

  public func plans() throws -> [PlanDocument] {
    try query("SELECT json FROM plans ORDER BY id", []) { row in
      try JSONCoding.decode(PlanDocument.self, from: row.text(0))
    }
  }

  public func decline(suggestion id: String) throws {
    try run("INSERT OR IGNORE INTO declined_suggestions (id) VALUES (?)", [id])
  }

  /// The ids of the group suggestions and the plan row suggestions that the
  /// user declined. A group suggestion's id starts with its kind, such as
  /// `merge:`. A plan row's id starts with its plan's id.
  public func declinedSuggestions() throws -> Set<String> {
    Set(try query("SELECT id FROM declined_suggestions", []) { $0.text(0) })
  }

  /// Saves the Claude sessions that sbd offers to import, in one transaction.
  public func save(claudeSessions: [ClaudeSession]) throws {
    try exec("BEGIN")
    do {
      for s in claudeSessions {
        try run("INSERT OR REPLACE INTO claude_sessions (id, json) VALUES (?, ?)", [s.id, try JSONCoding.encode(s)])
      }
      try exec("COMMIT")
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  public func claudeSessions() throws -> [ClaudeSession] {
    try query("SELECT json FROM claude_sessions ORDER BY id", []) { row in
      try JSONCoding.decode(ClaudeSession.self, from: row.text(0))
    }
  }

  public func delete(claudeSession id: String) throws {
    try run("DELETE FROM claude_sessions WHERE id = ?", [id])
  }

  @discardableResult
  public func append(_ event: Event) throws -> Event {
    try run(
      "INSERT INTO events (session, t, kind, data) VALUES (?, ?, ?, ?)",
      [event.session, event.t, event.kind, event.data.text])
    var stored = event
    stored.id = sqlite3_last_insert_rowid(db)
    return stored
  }

  /// Appends a hook event that a host's shim made, and records its id for the host, in one transaction. It
  /// returns nil, and stores nothing, when the id is already recorded, whatever host or session recorded it.
  public func append(_ event: Event, hostEvent id: HostEventID, host: String) throws -> Event? {
    try transaction {
      guard try !hasHostEvent(id) else { return nil }
      try run("INSERT INTO host_events (id, host, session) VALUES (?, ?, ?)", [id.text, host, event.session])
      return try append(event)
    }
  }

  public func hasHostEvent(_ id: HostEventID) throws -> Bool {
    !(try query("SELECT 1 FROM host_events WHERE id = ?", [id.text]) { $0.int(0) }).isEmpty
  }

  /// Whether the id is recorded for exactly this host and this session. The spool cut asks this, so a line
  /// that carries an id recorded for another host or another session is not one that sbd recorded.
  public func hasHostEvent(_ id: HostEventID, host: String, session: String) throws -> Bool {
    !(try query(
      "SELECT 1 FROM host_events WHERE id = ? AND host = ? AND session = ?", [id.text, host, session]
    ) { $0.int(0) }).isEmpty
  }

  /// Records that sbd removed the session `id` of `host`, so the spool cut may remove its leftover lines.
  public func recordRemovedHostSession(_ id: String, host: String) throws {
    try run("INSERT OR IGNORE INTO removed_host_sessions (id, host) VALUES (?, ?)", [id, host])
  }

  /// The ids of the sessions of `host` that sbd removed.
  public func removedHostSessions(host: String) throws -> Set<String> {
    Set(try query("SELECT id FROM removed_host_sessions WHERE host = ?", [host]) { $0.text(0) })
  }

  /// How far behind a host's newest id a recorded id is kept. It is far past the longest time an event can be
  /// in flight after its spool line is cut.
  public static let hostEventKeepNs: UInt64 = 24 * 3_600 * 1_000_000_000

  /// Removes the host's recorded ids whose clock is more than `hostEventKeepNs` behind the host's newest id.
  /// It also keeps every id whose clock is within that time of `nowNs`, so one id with a clock far ahead
  /// removes nothing that is recent. It removes no id at or above `floor`, the lowest recorded id whose line may
  /// still be in the host's spool: a line that stays in the spool is read again on each reconnect, and only its
  /// recorded id stops sbd from recording it twice.
  public func pruneHostEvents(host: String, nowNs: UInt64, keeping floor: HostEventID? = nil) throws {
    let newest = try query("SELECT id FROM host_events WHERE host = ? ORDER BY id DESC LIMIT 1", [host]) {
      HostEventID($0.text(0))?.ns
    }.first
    guard let newest = newest ?? nil else { return }
    let end = min(newest, nowNs)
    guard end > Store.hostEventKeepNs else { return }
    // Ids start with their clock as 20 digits, so ids below this text are the ids with an earlier clock.
    let digits = String(end - Store.hostEventKeepNs)
    let cutoff = String(repeating: "0", count: 20 - digits.count) + digits
    try run("DELETE FROM host_events WHERE host = ? AND id < ?", [host, floor.map { min($0.text, cutoff) } ?? cutoff])
  }

  /// The time of the session's last event, or nil for a session with none.
  public func lastEventTime(session: String) throws -> Int64? {
    try query("SELECT t FROM events WHERE session = ? ORDER BY id DESC LIMIT 1", [session]) { $0.int(0) }.first
  }

  /// Events with an id above `since`, oldest first, for one session or for
  /// all. It returns at most `limit` events: the oldest ones, or with
  /// `newest`, the newest ones.
  /// `sessions` limits the events to those sessions. `session` limits them to one.
  public func events(
    since: Int64 = 0, session: String? = nil, sessions: [String]? = nil, limit: Int = Int.max, newest: Bool = false
  ) throws -> [Event] {
    let ids = sessions ?? session.map { [$0] }
    if ids?.isEmpty == true { return [] }
    let filter = ids.map { " AND session IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))" } ?? ""
    var args: [Any] = [since]
    args += ids ?? []
    args.append(limit)
    let order = newest ? "DESC" : "ASC"
    let rows = try query(
      "\(Store.eventColumns) WHERE id > ?\(filter) ORDER BY id \(order) LIMIT ?", args, Store.event)
    return newest ? rows.reversed() : rows
  }

  private static let eventColumns = "SELECT id, session, t, kind, data FROM events"

  private static func event(_ row: Row) -> Event {
    Event(
      id: row.int(0), session: row.text(1), t: row.int(2), kind: row.text(3), data: JSON.parse(row.text(4)) ?? .null)
  }

  public func event(id: Int64) throws -> Event? {
    try query("\(Store.eventColumns) WHERE id = ?", [id], Store.event).first
  }

  /// The `send_decided` event that closed the session's group message card with this id.
  public func decision(card: Int64, session: String) throws -> Event? {
    try query(
      "\(Store.eventColumns) WHERE session = ? AND id > ? AND kind = 'send_decided' AND json_extract(data, '$.card') = ? LIMIT 1",
      [session, card, card], Store.event
    ).first
  }

  /// Records that an import read this line of Followups.md. Removing the
  /// follow-up keeps the row, so a later import still skips the line.
  public func recordImport(_ line: String) throws {
    try run("INSERT OR IGNORE INTO followup_imports (line) VALUES (?)", [line])
  }

  public func importedLines() throws -> Set<String> {
    Set(try query("SELECT line FROM followup_imports", []) { $0.text(0) })
  }

  // MARK: SQLite

  struct Row {
    let statement: OpaquePointer?
    func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(statement, i)) }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func optionalText(_ i: Int32) -> String? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : text(i) }
    func optionalInt(_ i: Int32) -> Int? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : Int(int(i)) }
  }

  /// Runs `body` in one transaction, so that a crash keeps all of its
  /// writes or none. It rolls them back and throws when `body` throws or the
  /// commit fails. It throws before `body` runs when the transaction can't
  /// start.
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try exec("COMMIT")
      return result
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
  }

  private func run(_ sql: String, _ args: [Any]) throws {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error(sql) }
  }

  private func query<T>(_ sql: String, _ args: [Any], _ map: (Row) throws -> T) throws -> [T] {
    let statement = try prepare(sql, args)
    defer { sqlite3_finalize(statement) }
    var out: [T] = []
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { return out }
      guard rc == SQLITE_ROW else { throw error(sql) }
      out.append(try map(Row(statement: statement)))
    }
  }

  // SQLITE_TRANSIENT makes SQLite copy each bound string.
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func prepare(_ sql: String, _ args: [Any]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
    for (i, arg) in args.enumerated() {
      let index = Int32(i + 1)
      switch arg {
      case let s as String: sqlite3_bind_text(statement, index, s, -1, Store.transient)
      case let n as Int64: sqlite3_bind_int64(statement, index, n)
      case let n as Int: sqlite3_bind_int64(statement, index, Int64(n))
      default: sqlite3_bind_null(statement, index)
      }
    }
    return statement
  }

  private func error(_ sql: String) -> APIError {
    APIError("\(String(cString: sqlite3_errmsg(db))) in: \(sql)")
  }
}
