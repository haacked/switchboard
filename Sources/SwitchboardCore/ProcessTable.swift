import Foundation

/// A process from a process table.
public struct ProcessRow: Sendable, Equatable {
  public var pid: Int
  public var ppid: Int
  public var pgid: Int
}

/// The processes of one machine, from one read.
public struct ProcessTable: Sendable {
  /// Every row, in the order of the read.
  public private(set) var all: [ProcessRow] = []
  private var rows: [Int: ProcessRow] = [:]
  private var childRows: [Int: [ProcessRow]] = [:]
  private var commands: [Int: String] = [:]

  public init() {}

  /// Every process on this Mac, from `ps` run through the machine. A failed run gives an empty table.
  public static func readLocal(on machine: any Machine) -> ProcessTable {
    guard let r = try? machine.run("/bin/ps", ["-axo", "pid=,ppid=,pgid=,command="]) else { return ProcessTable() }
    return parse(r.stdout)
  }

  /// The rows of `ps` output whose columns are pid, ppid, pgid, and the command. A line without three numbers
  /// is skipped. When two lines name the same pid, `row(_:)` and `command(of:)` answer from the first.
  public static func parse(_ psOutput: String) -> ProcessTable {
    var table = ProcessTable()
    for line in psOutput.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
      guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]), let pgid = Int(parts[2]) else {
        continue
      }
      let row = ProcessRow(pid: pid, ppid: ppid, pgid: pgid)
      table.all.append(row)
      table.childRows[ppid, default: []].append(row)
      if table.rows[pid] == nil {
        table.rows[pid] = row
        table.commands[pid] = parts.count > 3 ? String(parts[3]) : ""
      }
    }
    return table
  }

  /// The processes whose parent is the pid, in the order of the read.
  public func children(of pid: Int) -> [ProcessRow] { childRows[pid] ?? [] }

  public func row(_ pid: Int) -> ProcessRow? { rows[pid] }

  /// The command line of the process. It is nil for a pid that the table does not list.
  public func command(of pid: Int) -> String? { commands[pid] }

  /// Every pid in `roots` and every process below them.
  public func descendants(of roots: [Int]) -> Set<Int> {
    var found = Set(roots)
    var level = roots
    while !level.isEmpty {
      level = level.flatMap { children(of: $0) }.map(\.pid).filter { found.insert($0).inserted }
    }
    return found
  }
}
