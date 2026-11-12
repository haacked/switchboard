import Foundation
import Testing

/// Finds the names in `Sources` that reach this Mac without naming a session's site. Only `MacSite` may build a
/// `LocalMachine` or call the local process and path functions. A session path that used one of them would run a
/// remote session's work on this Mac.
enum SourceAudit {
  struct Finding: Equatable, CustomStringConvertible {
    /// The file's path below `Sources`.
    var file: String
    var line: Int
    var rule: String
    var description: String { "Sources/\(file):\(line): \(rule)" }
  }

  struct Rule {
    var name: String
    var pattern: NSRegularExpression
    /// The rule covers the files whose path below `Sources` starts with this.
    var under: String
    /// The files below `Sources` that may hold the name.
    var allowed: Set<String>

    init(_ name: String, _ pattern: String, under: String = "", allowed: Set<String> = []) {
      self.name = name
      // Every pattern is a constant of this file.
      self.pattern = try! NSRegularExpression(pattern: pattern)
      self.under = under
      self.allowed = allowed
    }
  }

  static let service = "SwitchboardService/"
  static let siteFile = "\(service)SessionSite.swift"
  static let serviceFile = "\(service)Service.swift"
  /// The files that hold no session work: the shared MCP servers and import, which run on this Mac.
  static let sessionless: Set<String> = ["\(service)Service+MCP.swift", "\(service)Service+Import.swift"]
  static let local = sessionless.union([siteFile])
  /// `Service+Sites.swift` holds the accessors that every session read of the snapshot goes through.
  static let snapshotReaders = local.union(["\(service)Service+Sites.swift"])

  /// A name counts as bare when no identifier and no `.` comes before it. `site.realPath(` and
  /// `mac.snapshot.panes` name their site, so they are not bare. `self.` names no site.
  private static let bare = #"(?<![A-Za-z0-9_.])(?:self\.)?"#

  static let rules: [Rule] = [
    Rule("= LocalMachine()", #"= LocalMachine\(\)"#),
    Rule("LocalMachine()", #"LocalMachine\(\)"#, allowed: [siteFile]),
    Rule("Processes.exists(", #"Processes\.exists\("#, under: service, allowed: local),
    Rule("Processes.waitForExit(", #"Processes\.waitForExit\("#, under: service, allowed: local),
    Rule("Processes.using(", #"Processes\.using\("#, under: service, allowed: local),
    Rule("realPath(", bare + #"realPath\("#, under: service, allowed: local),
    Rule("snapshot.panes", bare + #"snapshot\.panes\b"#, under: service, allowed: snapshotReaders),
    Rule("snapshot.claudePids", bare + #"snapshot\.claudePids\b"#, under: service, allowed: snapshotReaders),
    Rule("snapshot.children", bare + #"snapshot\.children\b"#, under: service, allowed: snapshotReaders),
    Rule("machine(for:)", #"(?<![A-Za-z0-9_])machine\(for\b"#, under: service),
    Rule("machine(of:)", #"(?<![A-Za-z0-9_])machine\(of\b"#, under: service),
    // Swift extensions hold no stored properties, so only `Service.swift` can give `Service` one.
    Rule("Service.host", #"\b(?:let|var)\s+host\s*:\s*TerminalHost\b"#, under: serviceFile),
    Rule("Service.git", #"\b(?:let|var)\s+git\s*:\s*String\b"#, under: serviceFile),
  ]

  /// The findings in one file's text. It reads comments too, as `grep` does.
  static func scan(file: String, text: String) -> [Finding] {
    let active = rules.filter { file.hasPrefix($0.under) && !$0.allowed.contains(file) }
    var findings: [Finding] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let line = String(line)
      let range = NSRange(line.startIndex..., in: line)
      for rule in active where rule.pattern.firstMatch(in: line, range: range) != nil {
        findings.append(Finding(file: file, line: index + 1, rule: rule.name))
      }
    }
    return findings
  }

  static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources").path

  /// Every Swift file below `Sources`, as its path below `Sources` and its text.
  static func sourceFiles() throws -> [(file: String, text: String)] {
    let names = (FileManager.default.enumerator(atPath: sources)?.compactMap { $0 as? String } ?? []).sorted()
    return try names.filter { $0.hasSuffix(".swift") }.map {
      ($0, try String(contentsOfFile: "\(sources)/\($0)", encoding: .utf8))
    }
  }

  static func scanSources() throws -> [Finding] {
    try sourceFiles().flatMap { scan(file: $0.file, text: $0.text) }
  }
}

@Suite struct SourceAuditTests {
  // MARK: The sources

  @Test func sourcesHoldNoForbiddenNameOutsideItsAllowedFiles() throws {
    let findings = try SourceAudit.scanSources()

    #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
  }

  @Test func sourcesBuildALocalMachineOnOneLineOfTheSiteFile() throws {
    let lines = try SourceAudit.sourceFiles().flatMap { source in
      source.text.split(separator: "\n").filter { $0.contains("LocalMachine()") }.map { "\(source.file): \($0)" }
    }

    #expect(lines.count == 1, "\(lines.joined(separator: "\n"))")
    #expect(lines.allSatisfy { $0.hasPrefix("\(SourceAudit.siteFile):") })
  }

  /// A renamed file would otherwise keep an allowance that covers nothing, or lose its rules.
  @Test func everyAllowedFileExists() {
    let allowed = SourceAudit.rules.reduce(into: Set<String>()) { $0.formUnion($1.allowed) }

    let missing = allowed.filter { !FileManager.default.fileExists(atPath: "\(SourceAudit.sources)/\($0)") }

    #expect(missing.isEmpty, "\(missing.sorted())")
  }

  @Test func theScanReadsTheSwiftFilesOfEveryTarget() throws {
    let files = Set(try SourceAudit.sourceFiles().map(\.file))

    #expect(files.contains("SwitchboardCore/Machine.swift"))
    #expect(files.contains("SwitchboardService/Service.swift"))
    #expect(files.contains("sbd/main.swift"))
    #expect(files.contains("sb/main.swift"))
  }

  // MARK: The scanner

  @Test(arguments: [
    ("SwitchboardService/Service.swift", "  func gitOutput(_ cwd: String, on machine: any Machine = LocalMachine()) {"),
    (
      "SwitchboardCore/Claude.swift",
      "  public static func tail(_ path: String, on machine: any Machine = LocalMachine())"
    ),
    ("SwitchboardService/SessionSite.swift", "    self.machine = LocalMachine()"),
    ("sbd/main.swift", "let machine = LocalMachine()"),
  ])
  func aLocalMachineDefaultOrAssignmentFailsInEveryFile(file: String, line: String) {
    let findings = SourceAudit.scan(file: file, text: line)

    #expect(findings.contains(SourceAudit.Finding(file: file, line: 1, rule: "= LocalMachine()")))
  }

  @Test(arguments: [
    ("SwitchboardService/Service.swift", "    return entries[id] == nil ? LocalMachine() : remote"),
    ("SwitchboardService/Service+Import.swift", "    Transcript.tail(path, on: LocalMachine())"),
    ("SwitchboardCore/Processes.swift", "    byParent(on: LocalMachine())"),
    ("sb/main.swift", "    return LocalMachine().size(path)"),
  ])
  func aLocalMachineBuiltOutsideTheSiteFileFails(file: String, line: String) {
    let findings = SourceAudit.scan(file: file, text: line)

    #expect(findings == [SourceAudit.Finding(file: file, line: 1, rule: "LocalMachine()")])
  }

  @Test func aLocalMachineBuiltInTheSiteFilePasses() {
    let findings = SourceAudit.scan(file: SourceAudit.siteFile, text: "  init() { self.init(machine: LocalMachine()) }")

    #expect(findings.isEmpty)
  }

  @Test(arguments: [
    ("    var users = Processes.using(session.cwd).filter { !running.contains($0.pid) }", "Processes.using("),
    ("      guard Processes.exists(pid) else { return nil }", "Processes.exists("),
    ("    let stuck = Processes.waitForExit(alive, seconds: 5)", "Processes.waitForExit("),
    ("    if let repo = s.repo { return realPath(repo) ?? repo }", "realPath("),
    ("    let main = entries.first.flatMap { realPath($0.path) }", "realPath("),
    ("    return self.realPath(path)", "realPath("),
    ("    if snapshot.panes[shell]?.dead == true { try closeShell(id) }", "snapshot.panes"),
    ("    for id in ids where self.snapshot.panes[id] == nil {", "snapshot.panes"),
    ("    snapshot.claudePids[id] = nil", "snapshot.claudePids"),
    ("    let owned = Set(snapshot.claudePids.values)", "snapshot.claudePids"),
    ("    ((children ?? snapshot.children)[pid] ?? []).filter { $0.pgid == $0.pid }.count", "snapshot.children"),
    ("  func machine(for session: Session) -> any Machine { site.machine }", "machine(for:)"),
    ("      machine(of: id).signal(pid, SIGTERM)", "machine(of:)"),
    ("    try self.machine(of: id).run(tool, [])", "machine(of:)"),
  ])
  func aLocalNameInSessionCodeFails(line: String, rule: String) {
    let file = "SwitchboardService/Service+FolderRelease.swift"

    let findings = SourceAudit.scan(file: file, text: line)

    #expect(findings == [SourceAudit.Finding(file: file, line: 1, rule: rule)])
  }

  @Test(arguments: [("  let host: TerminalHost", "Service.host"), ("  let git: String", "Service.git")])
  func aPropertyOfServiceThatHoldsThisMacsToolFails(line: String, rule: String) {
    let file = SourceAudit.serviceFile

    let findings = SourceAudit.scan(file: file, text: line)

    #expect(findings == [SourceAudit.Finding(file: file, line: 1, rule: rule)])
  }

  @Test(arguments: [
    "    var users = Processes.using(session.cwd)",
    "      guard Processes.exists(pid) else { return nil }",
    "    let stuck = Processes.waitForExit(alive, seconds: 5)",
    "    guard let root = realPath(folder) else { return [] }",
    "    let gone = snapshot.panes[server.pane] == nil",
    "    let owned = Set(snapshot.claudePids.values)",
    "    if backgroundJobs(pid, in: snapshot.children) > 0 {",
  ])
  func aLocalNameInTheSiteFileAndTheSessionlessFilesPasses(line: String) {
    for file in SourceAudit.local {
      #expect(SourceAudit.scan(file: file, text: line).isEmpty, "\(file)")
    }
  }

  @Test func theSnapshotAccessorsFileMayReadTheSnapshotButNotTheLocalProcessFunctions() {
    let file = "SwitchboardService/Service+Sites.swift"

    let read = SourceAudit.scan(file: file, text: "    snapshot.panes[paneName(id, pane)]")
    let local = SourceAudit.scan(file: file, text: "    Processes.using(folder)")

    #expect(read.isEmpty)
    #expect(local == [SourceAudit.Finding(file: file, line: 1, rule: "Processes.using(")])
  }

  /// A name that goes through a site, and a name that only looks like a forbidden one.
  @Test(arguments: [
    "    if let repo = s.repo { return try site(for: s).realPath(repo) ?? repo }",
    "    let gone = mac.snapshot.panes[server.pane] == nil",
    "    let pid = hostSnapshot.claudePids[id]",
    "    s.children = Processes.byParent(on: machine)",
    "    let all = Processes.descendants(of: pids.filter(Processes.isValidPid), in: s.children)",
    "    try worktreeEntries(repo, at: site).first { try site.samePath($0.path, path) }",
    "    let rows = snapshot.taken",
    "    /// The same processes that `Processes.using` names.",
    "    func machine(onHost name: String) -> (any Machine)? { hostLinks[name]?.machine }",
    "    let machine = try site(of: id).machine",
    "    guard let git = findExecutable(\"git\") else { throw APIError(\"can't find git\") }",
    "    for host in config.hosts { names.append(host.name) }",
    "  let hostLinks: [String: HostLink]",
  ])
  func aNameThatReachesItsSitePasses(line: String) {
    #expect(SourceAudit.scan(file: "SwitchboardService/Service.swift", text: line).isEmpty)
  }

  @Test func theProcessAndSnapshotRulesCoverOnlyTheService() {
    let line = "    guard let root = realPath(folder), Processes.exists(pid), snapshot.panes.isEmpty else { return [] }"

    #expect(SourceAudit.scan(file: "SwitchboardCore/FolderUsers.swift", text: line).isEmpty)
    #expect(SourceAudit.scan(file: "SwitchboardApp/Snapshot.swift", text: line).isEmpty)
  }

  @Test func aFindingNamesTheLineOfTheFile() {
    let text = "import Foundation\n\nfunc users() {\n  _ = Processes.using(\"/tmp\")\n}\n"

    let findings = SourceAudit.scan(file: "SwitchboardService/Service.swift", text: text)

    #expect(findings.map(\.description) == ["Sources/SwitchboardService/Service.swift:4: Processes.using("])
  }

  @Test func aLineWithTwoNamesGivesAFindingForEach() {
    let line = "  let m: any Machine = LocalMachine(); _ = Processes.using(cwd)"

    let rules = SourceAudit.scan(file: "SwitchboardService/Service.swift", text: line).map(\.rule)

    #expect(rules == ["= LocalMachine()", "LocalMachine()", "Processes.using("])
  }
}
