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
  }

  deinit { sqlite3_close(db) }

  public func save(_ session: Session) throws {
    try run("INSERT OR REPLACE INTO sessions (id, json) VALUES (?, ?)", [session.id, try JSONCoding.encode(session)])
  }

  public func delete(session id: String) throws {
    try run("DELETE FROM sessions WHERE id = ?", [id])
    try run("DELETE FROM events WHERE session = ?", [id])
  }

  public func sessions() throws -> [Session] {
    try query("SELECT json FROM sessions ORDER BY id", []) { row in
      try JSONCoding.decode(Session.self, from: row.text(0))
    }
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

  /// Events with an id above `since`, oldest first, for one session or for
  /// all. It returns at most `limit` events: the oldest ones, or with
  /// `newest`, the newest ones.
  public func events(since: Int64 = 0, session: String? = nil, limit: Int = Int.max, newest: Bool = false) throws
    -> [Event]
  {
    let filter = session == nil ? "" : " AND session = ?"
    var args: [Any] = [since]
    if let session { args.append(session) }
    args.append(limit)
    let order = newest ? "DESC" : "ASC"
    let rows = try query(
      "SELECT id, session, t, kind, data FROM events WHERE id > ?\(filter) ORDER BY id \(order) LIMIT ?", args
    ) { row in
      Event(
        id: row.int(0), session: row.text(1), t: row.int(2), kind: row.text(3), data: JSON.parse(row.text(4)) ?? .null)
    }
    return newest ? rows.reversed() : rows
  }

  // MARK: SQLite

  struct Row {
    let statement: OpaquePointer?
    func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(statement, i)) }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
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
