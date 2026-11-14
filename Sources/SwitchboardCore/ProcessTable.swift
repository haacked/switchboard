import Darwin
import Foundation

/// A process from a process table.
public struct ProcessRow: Sendable, Equatable {
  public var pid: Int
  public var ppid: Int
  public var pgid: Int
  /// Microseconds since the epoch. A row parsed from `ps` text holds 0.
  var startTime: Int64 = 0
  var isZombie = false
}

/// The processes of one machine, from one read.
public struct ProcessTable: Sendable {
  /// Every row, in the order of the read.
  public private(set) var all: [ProcessRow] = []
  private var rows: [Int: ProcessRow] = [:]
  private var childRows: [Int: [ProcessRow]] = [:]
  /// The command of each pid. When it is nil, `command(of:)` reads each command from the kernel when asked.
  private var commands: [Int: String]? = [:]

  public init() {}

  /// A table whose commands `command(of:)` reads from the kernel, with the rows in the given order.
  init(nativeRows: [ProcessRow]) {
    commands = nil
    all.reserveCapacity(nativeRows.count)
    rows.reserveCapacity(nativeRows.count)
    for row in nativeRows { append(row) }
  }

  /// Every process on this Mac, from one `sysctl` call. It runs no program. A failed read gives an empty table.
  public static func readLocal() -> ProcessTable {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    let stride = MemoryLayout<kinfo_proc>.stride
    // Processes can start between the size call and the read, so the read gets more room and retries on ENOMEM.
    for _ in 0..<3 {
      var size = 0
      guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return ProcessTable() }
      let capacity = (size + size / 10) / stride + 1
      var status: Int32 = 0
      var error: Int32 = 0
      let procs = [kinfo_proc](unsafeUninitializedCapacity: capacity) { buffer, count in
        size = capacity * stride
        status = sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0)
        error = errno
        count = status == 0 ? size / stride : 0
      }
      if status == 0 { return ProcessTable(listing: procs) }
      guard error == ENOMEM else { return ProcessTable() }
    }
    return ProcessTable()
  }

  /// The rows sorted as `ps` sorts them: by terminal device, then pid. A process without a terminal has device -1,
  /// so it comes first. `ps` never lists pid 0, the kernel.
  private init(listing procs: [kinfo_proc]) {
    let listed = procs.lazy.filter { $0.kp_proc.p_pid != 0 }.map { kp in
      (
        tty: kp.kp_eproc.e_tdev,
        row: ProcessRow(
          pid: Int(kp.kp_proc.p_pid), ppid: Int(kp.kp_eproc.e_ppid), pgid: Int(kp.kp_eproc.e_pgid),
          startTime: Self.startTime(kp), isZombie: Int32(kp.kp_proc.p_stat) == SZOMB)
      )
    }
    self.init(nativeRows: listed.sorted { ($0.tty, $0.row.pid) < ($1.tty, $1.row.pid) }.map(\.row))
  }

  /// The rows of `ps` output whose columns are pid, ppid, pgid, and the command. A line without three numbers
  /// is skipped. When two lines name the same pid, `row(_:)` and `command(of:)` answer from the first.
  public static func parse(_ psOutput: String) -> ProcessTable {
    var table = ProcessTable()
    var commands: [Int: String] = [:]
    for line in psOutput.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
      guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1]), let pgid = Int(parts[2]) else {
        continue
      }
      table.append(ProcessRow(pid: pid, ppid: ppid, pgid: pgid))
      if commands[pid] == nil { commands[pid] = parts.count > 3 ? String(parts[3]) : "" }
    }
    table.commands = commands
    return table
  }

  private mutating func append(_ row: ProcessRow) {
    all.append(row)
    childRows[row.ppid, default: []].append(row)
    if rows[row.pid] == nil { rows[row.pid] = row }
  }

  /// The processes whose parent is the pid, in the order of the read.
  public func children(of pid: Int) -> [ProcessRow] { childRows[pid] ?? [] }

  public func row(_ pid: Int) -> ProcessRow? { rows[pid] }

  /// The command line of the process. It is nil for a pid that the table does not list.
  ///
  /// A table from `readLocal()` reads the command when asked, as `ps` prints it. A row that the read listed as a
  /// zombie gives `<defunct>`. For any other row, the command is argv joined with spaces. When argv is unreadable, as
  /// another user's is, the command is the program's path, else the process's name in parentheses. After it reads the
  /// command, it reads the process's start time again. The command is nil when that start time differs from the
  /// row's or when the process is gone, because then the pid names another process or none.
  public func command(of pid: Int) -> String? {
    if let commands { return commands[pid] }
    guard let row = rows[pid], let id = pid_t(exactly: pid) else { return nil }
    if row.isZombie { return "<defunct>" }
    let argv = Self.argv(of: id)
    let path = argv.isEmpty ? Self.programPath(of: id) : nil
    guard let now = Processes.info(of: id), Self.startTime(now) == row.startTime else { return nil }
    if Int32(now.kp_proc.p_stat) == SZOMB { return "<defunct>" }
    if !argv.isEmpty { return argv.joined(separator: " ") }
    var name = now.kp_proc.p_comm
    return path ?? "(\(Processes.pathString(&name)))"
  }

  /// Every pid in `roots` and every process below them.
  public func descendants(of roots: [Int]) -> Set<Int> {
    var found = Set(roots)
    var level = roots
    while !level.isEmpty {
      level = level.flatMap { children(of: $0) }.map(\.pid).filter { found.insert($0).inserted }
    }
    return found
  }

  private static func startTime(_ kp: kinfo_proc) -> Int64 {
    let start = kp.kp_proc.p_un.__p_starttime
    return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
  }

  /// The process's argv as it reads now, which a process can overwrite to rename itself. It is empty when the kernel
  /// refuses the read, as it does for another user's process.
  static func argv(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let buffer = [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
      count = sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0) == 0 ? size : 0
    }
    return argv(fromProcArgs: buffer)
  }

  /// The argv in a `KERN_PROCARGS2` buffer, read as `ps` reads it. The buffer holds argc, the program path, NUL
  /// padding, argv, and then the environment. The parse stops at the end of the buffer, so it is empty for a buffer
  /// that ends before its first argument.
  static func argv(fromProcArgs buffer: [UInt8]) -> [String] {
    let argcSize = MemoryLayout<Int32>.size
    guard buffer.count >= argcSize else { return [] }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0, let pathEnd = buffer[argcSize...].firstIndex(of: 0) else { return [] }
    // An empty argv[0] reads as padding, as it does in ps.
    var rest = buffer[pathEnd...].drop { $0 == 0 }
    var args: [String] = []
    while args.count < argc, let end = rest.firstIndex(of: 0) {
      args.append(String(decoding: rest[..<end], as: UTF8.self))
      rest = rest[(end + 1)...]
    }
    return args
  }

  /// The path of the process's program, or nil when the kernel can't read it.
  static func programPath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
  }
}
