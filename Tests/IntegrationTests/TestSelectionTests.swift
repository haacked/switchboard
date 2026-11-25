import Foundation
import SwitchboardCore
import Testing

/// The package that the stub swift prints for `swift package dump-package`.
/// SwiftPM prints sorted keys with `" : "` between a key and its value, as
/// JSONSerialization does here.
private func packageJSON() throws -> Data {
  func byName(_ name: String) -> [String: Any] { ["byName": [name, NSNull()] as [Any]] }
  func product(_ name: String, _ package: String) -> [String: Any] {
    ["product": [name, package, NSNull(), NSNull()] as [Any]]
  }
  func target(_ name: String, _ type: String, exclude: [String] = [], _ dependencies: [[String: Any]]) -> [String: Any]
  {
    [
      "name": name, "type": type, "path": NSNull(), "exclude": exclude, "dependencies": dependencies,
      "resources": [Any](), "settings": [Any](),
    ]
  }
  let targets: [[String: Any]] = [
    target(
      "SwitchboardCore", "regular",
      [product("cmark-gfm", "swift-cmark"), product("cmark-gfm-extensions", "swift-cmark")]),
    target("SwitchboardService", "regular", [byName("SwitchboardCore")]),
    target("sbd", "executable", [byName("SwitchboardService")]),
    target("sb", "executable", [byName("SwitchboardCore")]),
    target("SwitchboardApp", "executable", [byName("SwitchboardCore"), product("SwiftTerm", "SwiftTerm")]),
    target("SwitchboardCoreTests", "test", exclude: ["Fixtures"], [byName("SwitchboardCore")]),
    target("SwitchboardServiceTests", "test", [byName("SwitchboardService"), byName("SwitchboardCore")]),
    target("SwitchboardAppTests", "test", [byName("SwitchboardApp"), byName("SwitchboardCore")]),
    target(
      "IntegrationTests", "test", exclude: ["Fixtures"],
      [byName("SwitchboardCore"), byName("sbd"), byName("sb")]),
  ]
  let package: [String: Any] = ["name": "Switchboard", "targets": targets]
  return try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
}

private func suiteFile(_ type: String, _ tests: String...) -> String {
  "import Testing\n\nstruct \(type) {\n" + tests.map { "  @Test func \($0)() {}\n" }.joined() + "}\n"
}

/// A suite whose one test builds a path from #filePath into `folder` under the
/// source folder, which the selection treats as reading the source folder.
private func sourceReaderFile(_ type: String, _ test: String, folder: String) -> String {
  """
  import Foundation
  import Testing

  struct \(type) {
    @Test func \(test)() {
      let dir = URL(fileURLWithPath: #filePath).appendingPathComponent("\(srcDir)/\(folder)")
      #expect(!dir.path.isEmpty)
    }
  }

  """
}

/// The source folder's name. The selection treats a test file that quotes this
/// name and finds the repo through #filePath or Instance.root as one that reads
/// the source folder at run time. This file builds the name so that the
/// selector does not treat this file that way.
private let srcDir = "Sour" + "ces"

/// The files of the baseline commit, which origin/main points at.
/// FxSourceScanTests.swift is the only file that reads the source folder.
/// FxRepoPathTests.swift quotes the folder's name only in a made-up path.
/// CLIMoreTests.swift names FxCLITests only as `extension FxCLITests`.
/// FxMergeTests.swift calls `fxGroupFixture()`, which FxGroupTests.swift declares.
/// No file uses Helpers.swift's `fxFixturePath`. FxRepoPathTests and FxGroupTests
/// are the smoke suites. The smoke list's `Nested.Skipped` line has too many parts,
/// so the selector skips it.
private let baselineFiles: [String: String] = [
  "Package.swift": "// swift-tools-version: 6.0\n",
  "README.md": "# Fixture\n",
  "bin/other": "#!/bin/sh\nexit 0\n",
  "\(srcDir)/SwitchboardCore/Core.swift": "public func fxCore() -> Int { 1 }\n",
  "\(srcDir)/SwitchboardService/Service.swift":
    "import SwitchboardCore\n\npublic func fxService() -> Int { fxCore() }\n",
  "\(srcDir)/sbd/main.swift": "import SwitchboardService\n\nprint(fxService())\n",
  "\(srcDir)/sb/main.swift": "import SwitchboardCore\n\nprint(fxCore())\n",
  "\(srcDir)/SwitchboardApp/App.swift": "import SwitchboardCore\n\nlet fxLaunched = fxCore()\n",
  "Tests/SwitchboardCoreTests/FxCoreTests.swift": suiteFile("FxCoreTests", "parses"),
  "Tests/SwitchboardCoreTests/Fixtures/sample.json": "{}\n",
  "Tests/SwitchboardServiceTests/FxServiceTests.swift": suiteFile("FxServiceTests", "starts", "stops"),
  "Tests/SwitchboardServiceTests/FxSourceScanTests.swift":
    sourceReaderFile("FxSourceScanTests", "scansSources", folder: "SwitchboardApp"),
  "Tests/SwitchboardAppTests/FxAppTests.swift": suiteFile("FxAppTests", "opens"),
  "Tests/IntegrationTests/FxCLITests.swift": suiteFile("FxCLITests", "lists"),
  "Tests/IntegrationTests/CLIMoreTests.swift": "import Testing\n\nextension FxCLITests {\n  @Test func more() {}\n}\n",
  "Tests/IntegrationTests/Helpers.swift": "func fxFixturePath(_ name: String) -> String { \"Fixtures/\" + name }\n",
  "Tests/IntegrationTests/FxGroupTests.swift": """
  import Testing

  func fxGroupFixture() -> String { "g" }

  struct FxGroupTests {
    @Test func groups() { #expect(fxGroupFixture() == "g") }
  }

  """,
  "Tests/IntegrationTests/FxMergeTests.swift": """
  import Testing

  struct FxMergeTests {
    @Test func merges() { #expect(fxGroupFixture() == "g") }
  }

  """,
  "Tests/IntegrationTests/FxRepoPathTests.swift": """
  import Testing

  struct FxRepoPathTests {
    @Test func addsAPath() { #expect(!"/tmp/x/\(srcDir)/deep".isEmpty) }
  }

  """,
  "Tests/IntegrationTests/Fixtures/claude-stub": "#!/bin/sh\nexit 0\n",
  "Tests/smoke-suites":
    "# Smoke suites\nIntegrationTests.FxRepoPathTests\nIntegrationTests.Nested.Skipped\nIntegrationTests.FxGroupTests\n",
]

/// The lines that `swift test list --skip-build` prints for the baseline files.
private let baselineListing = [
  "SwitchboardCoreTests.FxCoreTests/parses()",
  "SwitchboardServiceTests.FxServiceTests/starts()",
  "SwitchboardServiceTests.FxServiceTests/stops()",
  "SwitchboardServiceTests.FxSourceScanTests/scansSources()",
  "SwitchboardAppTests.FxAppTests/opens()",
  "IntegrationTests.FxCLITests/lists()",
  "IntegrationTests.FxCLITests/more()",
  "IntegrationTests.FxGroupTests/groups()",
  "IntegrationTests.FxMergeTests/merges()",
  "IntegrationTests.FxRepoPathTests/addsAPath()",
]

/// The swift invocations that one run of bin/test logged, each as its arguments.
private struct SelectionRun {
  let result: CommandResult
  let invocations: [[String]]

  /// The `swift test` invocations that run tests, as opposed to listing them.
  var testRuns: [[String]] { invocations.filter { $0.first == "test" && !Self.isList($0) } }

  var readPackage: Bool { invocations.contains { $0.contains("dump-package") } }

  /// The `swift build` invocations that compile, with their position among all invocations.
  var builds: [(index: Int, args: [String])] {
    invocations.enumerated().filter { $0.element.first == "build" && !$0.element.contains("--show-bin-path") }
      .map { ($0.offset, $0.element) }
  }

  /// The products that the builds named with `--product`, in the order built.
  var builtProducts: [String] {
    builds.flatMap { build in
      zip(build.args, build.args.dropFirst()).filter { $0.0 == "--product" }.map { $0.1 }
    }
  }

  static func isList(_ args: [String]) -> Bool {
    zip([""] + args, args).contains { prev, arg in arg == "list" && prev != "--filter" && prev != "--skip" }
  }

  static func filters(_ args: [String]) -> [String] { values("--filter", args) }

  static func skips(_ args: [String]) -> [String] { values("--skip", args) }

  /// The values of `option` in `args`, given as `option value` or `option=value`.
  static func values(_ option: String, _ args: [String]) -> [String] {
    var found: [String] = []
    var i = 0
    while i < args.count {
      if args[i] == option, i + 1 < args.count {
        found.append(args[i + 1])
        i += 2
        continue
      }
      if args[i].hasPrefix("\(option)=") { found.append(String(args[i].dropFirst(option.count + 1))) }
      i += 1
    }
    return found
  }
}

/// A temporary git repo with copies of bin/test and bin/lib, committed
/// with the baseline files. origin/main points at that commit. A stub swift
/// at the front of PATH logs its arguments, runs `dumpPackage` or prints the
/// package for `dump-package`, prints `listing` for `test list`, prints a
/// folder that holds a bundle for each name in `bundles` for
/// `build --show-bin-path`, and exits with `buildStatus` or `testStatus` for a
/// build or test run. A stub
/// xcode-select prints a developer folder that holds only Xcode's
/// Testing.framework, so bin/lib/swift-testing.sh passes and adds no flags.
private final class SelectionRepo {
  let repos: Repos
  let dir: String
  let stubBin: String
  let log: String
  let packagePath: String
  let developer: FakeDeveloperDir
  let listingPath: String
  var listing: [String]
  let binPath: String
  var bundles = ["SwitchboardCoreTests", "SwitchboardServiceTests", "SwitchboardAppTests", "IntegrationTests"]
  var buildStatus: Int32 = 0
  var testStatus: Int32 = 0
  var dumpPackage: String

  init(files: [String: String] = [:], listing extraListing: [String] = [], originMain: Bool = true) throws {
    repos = try Repos()
    dir = "\(repos.root)/repo"
    stubBin = "\(repos.root)/stub-bin"
    log = "\(repos.root)/swift.log"
    packagePath = "\(repos.root)/package.json"
    dumpPackage = "cat \(shellQuote(packagePath)); exit 0"
    developer = try FakeDeveloperDir(folders: [FakeDeveloperDir.xcodeFramework])
    listingPath = "\(repos.root)/listing.txt"
    binPath = "\(repos.root)/bin-path"
    listing = baselineListing + extraListing

    try Repos.create(dir)
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(dir)/bin/lib", withIntermediateDirectories: true)
    try fm.copyItem(atPath: Instance.root.appendingPathComponent("bin/test").path, toPath: "\(dir)/bin/test")
    let lib = Instance.root.appendingPathComponent("bin/lib").path
    for name in try fm.contentsOfDirectory(atPath: lib) {
      try fm.copyItem(atPath: "\(lib)/\(name)", toPath: "\(dir)/bin/lib/\(name)")
    }
    for (path, text) in baselineFiles.merging(files, uniquingKeysWith: { $1 }) { try write(path, text) }
    try commit("baseline")
    if originMain { try git("update-ref", "refs/remotes/origin/main", try git("rev-parse", "HEAD")) }

    try fm.createDirectory(atPath: stubBin, withIntermediateDirectories: true)
    try writeExecutable("\(stubBin)/xcode-select", "#!/bin/sh\nprintf '%s\\n' \(shellQuote(developer.path))\n")
    try packageJSON().write(to: URL(fileURLWithPath: packagePath))
  }

  @discardableResult
  func git(_ args: String...) throws -> String { try Repos.git(dir, args) }

  func write(_ path: String, _ text: String) throws {
    let full = "\(dir)/\(path)"
    try FileManager.default.createDirectory(
      atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: full, atomically: true, encoding: .utf8)
  }

  /// Appends a comment line in the file's syntax without committing.
  func append(_ path: String) throws {
    let full = "\(dir)/\(path)"
    let comment = path.hasSuffix(".swift") ? "// edited\n" : "# edited\n"
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: full))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(comment.utf8))
  }

  func commit(_ message: String) throws {
    try git("add", "-A")
    try Repos.commit(dir, message)
  }

  func edit(_ path: String) throws {
    try append(path)
    try commit("edit \(path)")
  }

  func add(_ path: String, _ text: String) throws {
    try write(path, text)
    try commit("add \(path)")
  }

  func delete(_ path: String) throws {
    try git("rm", "-q", path)
    try commit("delete \(path)")
  }

  func move(_ from: String, _ to: String) throws {
    try FileManager.default.createDirectory(
      atPath: ("\(dir)/\(to)" as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try git("mv", from, to)
    try commit("move \(from) to \(to)")
  }

  var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    env["PATH"] = "\(stubBin):\(env["PATH"] ?? "/usr/bin:/bin")"
    env.removeValue(forKey: "DEVELOPER_DIR")
    env.removeValue(forKey: "SB_TEST_CLAUDE")
    // The copied scripts skip the machine-wide build queue and pass no --jobs,
    // so the stub swift logs exactly the arguments that bin/test chose.
    env["SB_BUILD_SLOTS"] = "0"
    env["SB_BUILD_JOBS"] = "0"
    env.removeValue(forKey: "SB_BUILD_SLOT_HELD")
    return env
  }

  func run(_ args: String...) throws -> SelectionRun { try run(args) }

  func run(_ args: [String]) throws -> SelectionRun {
    try (listing.joined(separator: "\n") + "\n").write(toFile: listingPath, atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: binPath)
    for bundle in bundles {
      try FileManager.default.createDirectory(
        atPath: "\(binPath)/\(bundle).xctest", withIntermediateDirectories: true)
    }
    try writeExecutable(
      "\(stubBin)/swift",
      """
      #!/bin/bash
      (IFS=$'\\t'; printf '%s\\n' "$*") >> \(shellQuote(log))
      prev= dump=0 list=0 binpath=0
      for arg in "$@"; do
        case $arg in
          dump-package) dump=1 ;;
          --show-bin-path) binpath=1 ;;
          list) case $prev in --filter|--skip) ;; *) list=1 ;; esac ;;
        esac
        prev=$arg
      done
      if [ $dump = 1 ]; then \(dumpPackage); fi
      if [ $binpath = 1 ]; then printf '%s\\n' \(shellQuote(binPath)); exit 0; fi
      case ${1:-} in
        test) if [ $list = 1 ]; then cat \(shellQuote(listingPath)); exit 0; fi; exit \(testStatus) ;;
        build) exit \(buildStatus) ;;
      esac
      exit 0

      """)
    try? FileManager.default.removeItem(atPath: log)

    let result = try runCommand("/bin/bash", ["\(dir)/bin/test"] + args, env: environment, timeout: 60, cwd: dir)

    let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    let invocations = text.split(separator: "\n").map {
      $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
    return SelectionRun(result: result, invocations: invocations)
  }

  /// Sources bin/lib/test-selection.sh and runs `select_tests <package-json>`
  /// from the repo root with `paths` on stdin.
  func select(_ paths: [String]) throws -> CommandResult {
    let body = """
      set -euo pipefail
      source \(shellQuote("\(dir)/bin/lib/test-selection.sh"))
      select_tests "$(cat \(shellQuote(packagePath)))"
      """
    let input = Data(paths.map { "\($0)\n" }.joined().utf8)
    return try runCommand("/bin/bash", ["-c", body], env: environment, input: input, timeout: 30, cwd: dir)
  }

  private func writeExecutable(_ path: String, _ text: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }
}

private func wholeTarget(_ target: String) -> String { "^\(target)\\." }

private func suiteFilter(_ target: String, _ names: String...) -> String { suiteFilter(target, names) }

private func suiteFilter(_ target: String, _ names: [String]) -> String {
  "^\(target)\\.(\(names.sorted().joined(separator: "|")))/"
}

private func isIdentifier(_ text: Substring) -> Bool {
  !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

/// The target and suite names of a `^T\.` or `^T\.(A|B)/` filter. Suites are
/// nil for a whole-target filter. The result is nil for any other filter.
private func parseFilter(_ filter: String) -> (target: String, suites: [String]?)? {
  guard filter.hasPrefix("^"), let dot = filter.range(of: "\\.") else { return nil }
  let target = filter[filter.index(after: filter.startIndex)..<dot.lowerBound]
  guard isIdentifier(target) else { return nil }
  var rest = filter[dot.upperBound...]
  if rest.isEmpty { return (String(target), nil) }
  guard rest.hasSuffix("/") else { return nil }
  rest = rest.dropLast()
  if rest.hasPrefix("("), rest.hasSuffix(")") { rest = rest.dropFirst().dropLast() }
  let names = rest.split(separator: "|", omittingEmptySubsequences: false)
  guard names.allSatisfy(isIdentifier) else { return nil }
  return (String(target), names.map(String.init))
}

/// The filters with the same meaning in one form. The suites of a target
/// merge into one sorted alternation. A target's suite filter drops out when
/// its whole-target filter is present. `^T\.A/` becomes `^T\.(A)/`.
private func canonicalFilters(_ filters: [String]) -> Set<String> {
  var whole = Set<String>()
  var suites: [String: Set<String>] = [:]
  var result = Set<String>()
  for filter in filters {
    guard let parsed = parseFilter(filter) else {
      result.insert(filter)
      continue
    }
    if let names = parsed.suites {
      suites[parsed.target, default: []].formUnion(names)
    } else {
      whole.insert(parsed.target)
    }
  }
  result.formUnion(whole.map(wholeTarget))
  for (target, names) in suites where !whole.contains(target) { result.insert(suiteFilter(target, Array(names))) }
  return result
}

/// Checks that bin/test ran swift test once with `--skip-build` and exactly
/// `filters`, exited 0, and said that CI runs the rest. Returns the run's
/// position among the invocations.
@discardableResult
private func expectFilteredRun(
  _ run: SelectionRun, _ filters: Set<String>, sourceLocation: SourceLocation = #_sourceLocation
) -> Int? {
  #expect(run.result.status == 0, "\(run.result.stderr)", sourceLocation: sourceLocation)
  #expect(run.testRuns.count == 1, "\(run.invocations)", sourceLocation: sourceLocation)
  guard let args = run.testRuns.first, let runIndex = run.invocations.firstIndex(of: args) else { return nil }
  #expect(
    canonicalFilters(SelectionRun.filters(args)) == canonicalFilters(Array(filters)), "\(args)",
    sourceLocation: sourceLocation)
  #expect(args.contains("--skip-build"), "\(args)", sourceLocation: sourceLocation)
  #expect(
    run.result.stderr.contains("CI runs every other test on every push"), "\(run.result.stderr)",
    sourceLocation: sourceLocation)
  return runIndex
}

/// Checks that bin/test built exactly the bundles of the targets that `filters` name,
/// each with `--product` and before the run, then ran as `expectFilteredRun` checks.
private func expectTargeted(
  _ run: SelectionRun, _ filters: Set<String>, sourceLocation: SourceLocation = #_sourceLocation
) {
  guard let runIndex = expectFilteredRun(run, filters, sourceLocation: sourceLocation) else { return }
  expectProductBuildsBefore(run, runIndex, sourceLocation: sourceLocation)
  // A bundle that a filter names must be a bundle that this run built, because a bundle
  // that it did not build can hold tests from before the change.
  let filterTargets = Set(filters.compactMap { parseFilter($0)?.target })
  #expect(Set(run.builtProducts) == filterTargets, "\(run.invocations)", sourceLocation: sourceLocation)
}

/// Checks that bin/test built at least one bundle, and that each build came before the
/// run and named one product.
private func expectProductBuildsBefore(
  _ run: SelectionRun, _ runIndex: Int, sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(!run.builds.isEmpty, "\(run.invocations)", sourceLocation: sourceLocation)
  for build in run.builds {
    #expect(build.index < runIndex, "\(run.invocations)", sourceLocation: sourceLocation)
    #expect(!build.args.contains("--build-tests"), "\(build.args)", sourceLocation: sourceLocation)
    // swift build honors only the last --product it is given, so a second one would leave a bundle stale.
    #expect(build.args.filter { $0 == "--product" }.count == 1, "\(build.args)", sourceLocation: sourceLocation)
  }
}

/// Checks that bin/test built every test bundle in one `--build-tests` build
/// before the run, then ran as `expectFilteredRun` checks.
private func expectBuiltEveryBundle(
  _ run: SelectionRun, _ filters: Set<String>, sourceLocation: SourceLocation = #_sourceLocation
) {
  guard let runIndex = expectFilteredRun(run, filters, sourceLocation: sourceLocation) else { return }
  #expect(run.builds.count == 1, "\(run.invocations)", sourceLocation: sourceLocation)
  #expect(
    run.builds.first.map { $0.index < runIndex && $0.args.contains("--build-tests") } == true,
    "\(run.invocations)", sourceLocation: sourceLocation)
  #expect(run.builtProducts.isEmpty, "\(run.invocations)", sourceLocation: sourceLocation)
  #expect(
    run.result.stderr.contains("so every test bundle builds"), "\(run.result.stderr)", sourceLocation: sourceLocation)
}

/// A change to the baseline repo and the filters bin/test should then pass.
private struct SelectionCase: Sendable, CustomTestStringConvertible {
  var name: String
  var files: [String: String] = [:]
  var listing: [String] = []
  var change: @Sendable (SelectionRepo) throws -> Void
  var filters: Set<String>

  var testDescription: String { name }

  func check() throws {
    let repo = try SelectionRepo(files: files, listing: listing)
    try change(repo)

    let run = try repo.run()

    expectTargeted(run, filters)
  }
}

private let sourceScanSuite = suiteFilter("SwitchboardServiceTests", "FxSourceScanTests")

/// The unit test targets. A source change leaves IntegrationTests to CI.
private let unitTargetNames = ["SwitchboardCoreTests", "SwitchboardServiceTests", "SwitchboardAppTests"]

private let unitTargets = Set(unitTargetNames.map(wholeTarget))

/// The suites that the baseline's Tests/smoke-suites lists.
private let smoke = suiteFilter("IntegrationTests", "FxRepoPathTests", "FxGroupTests")

/// What a change that no rule maps selects.
private let unitsAndSmoke = unitTargets.union([smoke])

private let sourceCases: [SelectionCase] = [
  SelectionCase(name: "Core", change: { try $0.edit("\(srcDir)/SwitchboardCore/Core.swift") }, filters: unitTargets),
  SelectionCase(
    name: "Service", change: { try $0.edit("\(srcDir)/SwitchboardService/Service.swift") },
    filters: [wholeTarget("SwitchboardServiceTests")]),
  SelectionCase(
    name: "sbd", change: { try $0.edit("\(srcDir)/sbd/main.swift") },
    filters: [sourceScanSuite]),
  SelectionCase(
    name: "sb", change: { try $0.edit("\(srcDir)/sb/main.swift") },
    filters: [sourceScanSuite]),
  SelectionCase(
    name: "sb with an IntegrationTests file that reads the source folder",
    files: [
      "Tests/IntegrationTests/FxSourceReadTests.swift": sourceReaderFile("FxSourceReadTests", "reads", folder: "sb")
    ],
    listing: ["IntegrationTests.FxSourceReadTests/reads()"],
    change: { try $0.edit("\(srcDir)/sb/main.swift") },
    filters: [sourceScanSuite]),
  SelectionCase(
    name: "Core and an IntegrationTests test file",
    change: { repo in
      try repo.edit("\(srcDir)/SwitchboardCore/Core.swift")
      try repo.edit("Tests/IntegrationTests/FxCLITests.swift")
    }, filters: unitTargets.union([suiteFilter("IntegrationTests", "FxCLITests")])),
  SelectionCase(
    name: "Core and an IntegrationTests helper",
    change: { repo in
      try repo.edit("\(srcDir)/SwitchboardCore/Core.swift")
      try repo.edit("Tests/IntegrationTests/Helpers.swift")
    }, filters: unitsAndSmoke),
  SelectionCase(
    name: "App", change: { try $0.edit("\(srcDir)/SwitchboardApp/App.swift") },
    filters: [wholeTarget("SwitchboardAppTests"), sourceScanSuite]),
  SelectionCase(
    name: "new App file", change: { try $0.add("\(srcDir)/SwitchboardApp/FxToolbar.swift", "struct FxToolbar {}\n") },
    filters: [wholeTarget("SwitchboardAppTests"), sourceScanSuite]),
  SelectionCase(
    name: "deleted sb file", change: { try $0.delete("\(srcDir)/sb/main.swift") },
    filters: [sourceScanSuite]),
  SelectionCase(
    name: "App file moved into sb",
    change: { try $0.move("\(srcDir)/SwitchboardApp/App.swift", "\(srcDir)/sb/App.swift") },
    filters: [wholeTarget("SwitchboardAppTests"), sourceScanSuite]),
]

private let suiteCases: [SelectionCase] =
  [
    SelectionCase(
      name: "test file", change: { try $0.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift") },
      filters: [suiteFilter("SwitchboardServiceTests", "FxServiceTests")]),
    SelectionCase(
      name: "suite another file names only as an extension",
      change: { try $0.edit("Tests/IntegrationTests/FxCLITests.swift") },
      filters: [suiteFilter("IntegrationTests", "FxCLITests")]),
    SelectionCase(
      name: "suite that calls another file's helper",
      change: { try $0.edit("Tests/IntegrationTests/FxMergeTests.swift") },
      filters: [suiteFilter("IntegrationTests", "FxMergeTests")]),
    SelectionCase(
      name: "private helper whose name another file also declares privately",
      files: [
        "Tests/IntegrationTests/FxPrivateTests.swift":
          "import Testing\n\nprivate func fxLocalHelper() -> Int { 1 }\n\nstruct FxPrivateTests {\n  @Test func a() { #expect(fxLocalHelper() == 1) }\n}\n",
        "Tests/IntegrationTests/FxFilePrivateTests.swift":
          "import Testing\n\nfileprivate func fxLocalHelper() -> Int { 2 }\n\nstruct FxFilePrivateTests {\n  @Test func b() { #expect(fxLocalHelper() == 2) }\n}\n",
      ],
      listing: ["IntegrationTests.FxPrivateTests/a()", "IntegrationTests.FxFilePrivateTests/b()"],
      change: { try $0.edit("Tests/IntegrationTests/FxPrivateTests.swift") },
      filters: [suiteFilter("IntegrationTests", "FxPrivateTests")]),
  ]
  + suiteShapes.map { shape in
    SelectionCase(
      name: shape.name, listing: shape.names.map { "IntegrationTests.\($0)/a()" },
      change: { try $0.add("Tests/IntegrationTests/FxShapeTests.swift", shape.text) },
      filters: [suiteFilter("IntegrationTests", shape.names)])
  }

/// Ways to write the top-level types of a new test file, with the type names.
/// Each type holds one test named `a`.
private let suiteShapes: [(name: String, text: String, names: [String])] = [
  (
    "@Suite struct", "import Testing\n\n@Suite(.serialized) struct FxShapeTests {\n  @Test func a() {}\n}\n",
    ["FxShapeTests"]
  ),
  (
    "@Suite with a display name",
    "import Testing\n\n@Suite(\"Shapes\") struct FxShapeTests {\n  @Test func a() {}\n}\n", ["FxShapeTests"]
  ),
  ("final class", "import Testing\n\nfinal class FxShapeTests {\n  @Test func a() {}\n}\n", ["FxShapeTests"]),
  ("enum", "import Testing\n\nenum FxShapeTests {\n  @Test static func a() {}\n}\n", ["FxShapeTests"]),
  ("actor", "import Testing\n\nactor FxShapeTests {\n  @Test func a() {}\n}\n", ["FxShapeTests"]),
  (
    "@MainActor struct", "import Testing\n\n@MainActor struct FxShapeTests {\n  @Test func a() {}\n}\n",
    ["FxShapeTests"]
  ),
  (
    "two structs",
    "import Testing\n\nstruct FxShapeTests {\n  @Test func a() {}\n}\n\nstruct FxOtherShapeTests {\n  @Test func a() {}\n}\n",
    ["FxShapeTests", "FxOtherShapeTests"]
  ),
]

private let mixedFile = "Tests/SwitchboardCoreTests/FxMixedTests.swift"

private func mixedText(_ free: String) -> String {
  "import Testing\n\nstruct FxMixedTests {\n  @Test func inSuite() {}\n}\n\n\(free)"
}

/// Ways to write a free test function beside a suite. The last two do not
/// start a line with `@Test`, so only the listing count catches them.
private let freeTests: [(name: String, text: String)] = [
  ("@Test", "@Test func free() {}\n"),
  ("@Test with a display name", "@Test(\"Free\") func free() {}\n"),
  ("@Test with arguments", "@Test(arguments: [1, 2]) func free(_ n: Int) {}\n"),
  ("@MainActor @Test", "@MainActor @Test func free() {}\n"),
  ("@Test indented under #if", "#if os(macOS)\n  @Test func free() {}\n#endif\n"),
]

/// An IntegrationTests file that the selector cannot narrow to its own suites
/// selects them and the suites of the files that use its names, or the smoke
/// suites in their place.
private let integrationFileCases: [SelectionCase] = [
  SelectionCase(
    name: "deleted test file", change: { try $0.delete("Tests/IntegrationTests/FxMergeTests.swift") },
    filters: [smoke]),
  SelectionCase(
    name: "helper file of functions", change: { try $0.edit("Tests/IntegrationTests/Helpers.swift") },
    filters: [smoke]),
  SelectionCase(
    name: "helper file of a type",
    files: ["Tests/IntegrationTests/FxServer.swift": "final class FxServer {\n  func start() {}\n}\n"],
    change: { try $0.edit("Tests/IntegrationTests/FxServer.swift") },
    filters: [smoke]),
  SelectionCase(
    name: "namespace enum that other files extend with suites",
    files: [
      "Tests/IntegrationTests/FxToolServerTests.swift": "enum FxToolServerTests {}\n",
      "Tests/IntegrationTests/MCPScopedTests.swift":
        "import Testing\n\nextension FxToolServerTests {\n  @Suite struct FxScoped {\n    @Test func calls() {}\n  }\n}\n",
    ],
    listing: ["IntegrationTests.FxToolServerTests/FxScoped/calls()"],
    change: { try $0.edit("Tests/IntegrationTests/FxToolServerTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxToolServerTests")]),
  SelectionCase(
    name: "top-level function another file calls",
    change: { try $0.edit("Tests/IntegrationTests/FxGroupTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxGroupTests", "FxMergeTests")]),
  SelectionCase(
    name: "suite type another file names",
    files: [
      "Tests/IntegrationTests/FxHostTests.swift":
        "import Testing\n\nstruct FxHostTests {\n  static let name = \"h\"\n  @Test func resolves() {}\n}\n",
      "Tests/IntegrationTests/FxHostScopeTests.swift":
        "import Testing\n\nstruct FxHostScopeTests {\n  @Test func scopes() { #expect(FxHostTests.name == \"h\") }\n}\n",
    ],
    listing: ["IntegrationTests.FxHostTests/resolves()", "IntegrationTests.FxHostScopeTests/scopes()"],
    change: { try $0.edit("Tests/IntegrationTests/FxHostTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxHostTests", "FxHostScopeTests")]),
  SelectionCase(
    name: "top-level constant another file reads",
    files: [
      "Tests/IntegrationTests/FxTimeoutTests.swift":
        "import Testing\n\nlet fxSharedTimeout = 5\n\nstruct FxTimeoutTests {\n  @Test func waits() { #expect(fxSharedTimeout == 5) }\n}\n",
      "Tests/IntegrationTests/FxRetryTests.swift":
        "import Testing\n\nstruct FxRetryTests {\n  @Test func retries() { #expect(fxSharedTimeout > 0) }\n}\n",
    ],
    listing: ["IntegrationTests.FxTimeoutTests/waits()", "IntegrationTests.FxRetryTests/retries()"],
    change: { try $0.edit("Tests/IntegrationTests/FxTimeoutTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxTimeoutTests", "FxRetryTests")]),
  // FxEchoTests never names the extended type. Changing `fxShouted` still
  // changes what FxEchoTests runs, so the smoke suites stand in for it.
  SelectionCase(
    name: "extension of a non-suite type whose member another suite uses",
    files: [
      "Tests/IntegrationTests/FxShoutTests.swift":
        "import Testing\n\nextension Substring {\n  var fxShouted: String { uppercased() }\n}\n\nstruct FxShoutTests {\n  @Test func shouts() { #expect(\"a\".dropFirst(0).fxShouted == \"A\") }\n}\n",
      "Tests/IntegrationTests/FxEchoTests.swift":
        "import Testing\n\nstruct FxEchoTests {\n  @Test func echoes() { #expect(\"b\".dropFirst(0).fxShouted == \"B\") }\n}\n",
    ],
    listing: ["IntegrationTests.FxShoutTests/shouts()", "IntegrationTests.FxEchoTests/echoes()"],
    change: { try $0.edit("Tests/IntegrationTests/FxShoutTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxShoutTests", "Substring"), smoke]),
  SelectionCase(
    name: "extension of a type the parse cannot name whose member another suite uses",
    files: [
      "Tests/IntegrationTests/FxTallyTests.swift":
        "import Testing\n\nextension [String: Int] {\n  var fxTotal: Int { values.reduce(0, +) }\n}\n\nstruct FxTallyTests {\n  @Test func totals() { #expect([\"a\": 1].fxTotal == 1) }\n}\n",
      "Tests/IntegrationTests/FxSumTests.swift":
        "import Testing\n\nstruct FxSumTests {\n  @Test func sums() { #expect([\"b\": 2].fxTotal == 2) }\n}\n",
    ],
    listing: ["IntegrationTests.FxTallyTests/totals()", "IntegrationTests.FxSumTests/sums()"],
    change: { try $0.edit("Tests/IntegrationTests/FxTallyTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxTallyTests"), smoke]),
  SelectionCase(
    name: "helper under #if that another suite uses",
    files: [
      "Tests/IntegrationTests/FxPlatformTests.swift":
        "import Testing\n\n#if os(macOS)\n  func fxPlatformHelper() -> Int { 1 }\n#endif\n\nstruct FxPlatformTests {\n  @Test func runs() { #expect(fxPlatformHelper() == 1) }\n}\n",
      "Tests/IntegrationTests/FxPlatformUserTests.swift":
        "import Testing\n\nstruct FxPlatformUserTests {\n  @Test func uses() { #expect(fxPlatformHelper() == 1) }\n}\n",
    ],
    listing: ["IntegrationTests.FxPlatformTests/runs()", "IntegrationTests.FxPlatformUserTests/uses()"],
    change: { try $0.edit("Tests/IntegrationTests/FxPlatformTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxPlatformTests"), smoke]),
  SelectionCase(
    name: "helper whose only user declares tests outside a type",
    files: [
      "Tests/IntegrationTests/FxValue.swift": "func fxValue() -> Int { 1 }\n",
      "Tests/IntegrationTests/FxFreeUserTests.swift":
        "import Testing\n\n@Test func checksValue() { #expect(fxValue() == 1) }\n",
    ],
    change: { try $0.edit("Tests/IntegrationTests/FxValue.swift") },
    filters: [smoke]),
  SelectionCase(
    name: "file with a test outside a type and a helper another suite uses",
    files: [
      "Tests/IntegrationTests/FxFreeOwnTests.swift":
        "import Testing\n\nfunc fxOwnHelper() -> Int { 1 }\n\n@Test func free() { #expect(fxOwnHelper() == 1) }\n",
      "Tests/IntegrationTests/FxOwnUserTests.swift":
        "import Testing\n\nstruct FxOwnUserTests {\n  @Test func uses() { #expect(fxOwnHelper() == 1) }\n}\n",
    ],
    listing: ["IntegrationTests.free()", "IntegrationTests.FxOwnUserTests/uses()"],
    change: { try $0.edit("Tests/IntegrationTests/FxFreeOwnTests.swift") },
    filters: [suiteFilter("IntegrationTests", "FxOwnUserTests"), smoke]),
  SelectionCase(
    name: "helper as many files use as the cap allows",
    files: sharedHelperFiles(users: 10), listing: sharedHelperListing(users: 10),
    change: { try $0.edit("Tests/IntegrationTests/FxShared.swift") },
    filters: [suiteFilter("IntegrationTests", (0..<10).map { "FxUser\($0)Tests" })]),
  SelectionCase(
    name: "helper more files use than the cap allows",
    files: sharedHelperFiles(users: 11), listing: sharedHelperListing(users: 11),
    change: { try $0.edit("Tests/IntegrationTests/FxShared.swift") },
    filters: [smoke]),
]

/// FxShared.swift declares `fxShared()`, and `users` suites with one test each call it.
private func sharedHelperFiles(users: Int) -> [String: String] {
  var files = ["Tests/IntegrationTests/FxShared.swift": "func fxShared() -> Int { 1 }\n"]
  for i in 0..<users {
    files["Tests/IntegrationTests/FxUser\(i)Tests.swift"] =
      "import Testing\n\nstruct FxUser\(i)Tests {\n  @Test func a() { #expect(fxShared() == 1) }\n}\n"
  }
  return files
}

private func sharedHelperListing(users: Int) -> [String] {
  (0..<users).map { "IntegrationTests.FxUser\($0)Tests/a()" }
}

private let wholeTargetCases: [SelectionCase] =
  [
    SelectionCase(
      name: "deleted test file", change: { try $0.delete("Tests/SwitchboardServiceTests/FxServiceTests.swift") },
      filters: [wholeTarget("SwitchboardServiceTests")]),
    SelectionCase(
      name: "test file deleted without a commit",
      change: {
        try FileManager.default.removeItem(atPath: "\($0.dir)/Tests/SwitchboardServiceTests/FxServiceTests.swift")
      },
      filters: [wholeTarget("SwitchboardServiceTests")]),
    SelectionCase(
      name: "test file renamed in its target",
      change: {
        try $0.move(
          "Tests/SwitchboardServiceTests/FxServiceTests.swift", "Tests/SwitchboardServiceTests/ServiceSuiteTests.swift")
      },
      filters: [wholeTarget("SwitchboardServiceTests")]),
    SelectionCase(
      name: "test file moved to another target",
      change: { repo in
        try repo.move(
          "Tests/SwitchboardServiceTests/FxServiceTests.swift", "Tests/IntegrationTests/FxServiceTests.swift")
        repo.listing = repo.listing.map {
          $0.replacingOccurrences(
            of: "SwitchboardServiceTests.FxServiceTests/", with: "IntegrationTests.FxServiceTests/")
        }
      },
      filters: [wholeTarget("SwitchboardServiceTests"), suiteFilter("IntegrationTests", "FxServiceTests")]),
  ]
  + freeTests.map { free in
    SelectionCase(
      name: "free function: \(free.name)",
      files: [mixedFile: mixedText(free.text)],
      listing: ["SwitchboardCoreTests.FxMixedTests/inSuite()", "SwitchboardCoreTests.free()"],
      change: { try $0.edit(mixedFile) },
      filters: [wholeTarget("SwitchboardCoreTests")])
  }
  + [
    SelectionCase(
      name: "free function beside a suite that another file extends",
      files: [
        mixedFile: mixedText("@MainActor @Test func free() {}\n"),
        "Tests/SwitchboardCoreTests/FxMixedMoreTests.swift":
          "import Testing\n\nextension FxMixedTests {\n  @Test func more() {}\n}\n",
      ],
      listing: [
        "SwitchboardCoreTests.FxMixedTests/inSuite()", "SwitchboardCoreTests.FxMixedTests/more()",
        "SwitchboardCoreTests.free()",
      ],
      change: { try $0.edit(mixedFile) },
      filters: [wholeTarget("SwitchboardCoreTests")])
  ]

/// The FxServiceTests file has two tests, and each listing shows fewer under
/// the file's suite, as after a stale build.
private let listingFallbackCases: [SelectionCase] = [
  SelectionCase(
    name: "listing lacks one of the file's tests",
    change: { repo in
      try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")
      repo.listing.removeAll { $0 == "SwitchboardServiceTests.FxServiceTests/stops()" }
    },
    filters: [wholeTarget("SwitchboardServiceTests")]),
  SelectionCase(
    name: "listing lacks the file's suite",
    change: { repo in
      try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")
      repo.listing.removeAll { $0.hasPrefix("SwitchboardServiceTests.FxServiceTests/") }
    },
    filters: [wholeTarget("SwitchboardServiceTests")]),
  SelectionCase(
    name: "listing is empty, so list_tests fails",
    change: { repo in
      try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")
      repo.listing = []
    },
    filters: [wholeTarget("SwitchboardServiceTests")]),
  SelectionCase(
    name: "listing lacks one of two suites",
    listing: ["IntegrationTests.FxShapeTests/a()"],
    change: {
      try $0.add(
        "Tests/IntegrationTests/FxShapeTests.swift",
        "import Testing\n\nstruct FxShapeTests {\n  @Test func a() {}\n}\n\nstruct FxOtherShapeTests {\n  @Test func a() {}\n}\n"
      )
    },
    filters: [suiteFilter("IntegrationTests", "FxShapeTests", "FxOtherShapeTests"), smoke]),
]

private let unknownCases: [SelectionCase] = [
  SelectionCase(
    name: "FxCoreTests fixture", change: { try $0.edit("Tests/SwitchboardCoreTests/Fixtures/sample.json") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "deleted FxCoreTests fixture", change: { try $0.delete("Tests/SwitchboardCoreTests/Fixtures/sample.json") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "IntegrationTests fixture script", change: { try $0.edit("Tests/IntegrationTests/Fixtures/claude-stub") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "Swift file under Fixtures",
    change: { try $0.add("Tests/SwitchboardCoreTests/Fixtures/FxStub.swift", "struct FxStub {}\n") },
    filters: unitsAndSmoke),
  SelectionCase(name: "Package.swift", change: { try $0.edit("Package.swift") }, filters: unitsAndSmoke),
  SelectionCase(name: "Package.resolved", change: { try $0.add("Package.resolved", "{}\n") }, filters: unitsAndSmoke),
  SelectionCase(name: "bin file", change: { try $0.edit("bin/other") }, filters: unitsAndSmoke),
  SelectionCase(name: "new bin file", change: { try $0.add("bin/measure", "#!/bin/sh\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "workflow", change: { try $0.add(".github/workflows/ci.yml", "name: CI\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "Tests/GUI Swift file",
    change: { try $0.add("Tests/GUI/FxWindowTests.swift", suiteFile("FxWindowTests", "opens")) },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "Tests/shard-weights", change: { try $0.add("Tests/shard-weights", "1.0 IntegrationTests.FxCLITests\n") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "Swift file in a folder that is no target",
    change: { try $0.add("\(srcDir)/Retired/FxThing.swift", "struct FxThing {}\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "folder whose name starts with a target's name",
    change: { try $0.add("\(srcDir)/SwitchboardAppKit/FxPanel.swift", "struct FxPanel {}\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "test folder whose name starts with a test target's name",
    change: { try $0.add("Tests/SwitchboardAppTestsSupport/FxFake.swift", "struct FxFake {}\n") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "Markdown below the root", change: { try $0.add("docs/testing.md", "# Testing\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "Markdown in a source target", change: { try $0.add("\(srcDir)/SwitchboardCore/notes.md", "# Notes\n") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "Markdown in a test target", change: { try $0.add("Tests/SwitchboardServiceTests/README.md", "# Tests\n") },
    filters: unitsAndSmoke),
  SelectionCase(
    name: "resource in a source target",
    change: { try $0.add("\(srcDir)/SwitchboardCore/Resources/strings.json", "{}\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "text file in a test target", change: { try $0.add("Tests/SwitchboardAppTests/notes.txt", "note\n") },
    filters: unitsAndSmoke),
  SelectionCase(name: "root dotfile", change: { try $0.add(".swift-format", "{}\n") }, filters: unitsAndSmoke),
  SelectionCase(
    name: "root Markdown and Package.swift",
    change: { repo in
      try repo.append("README.md")
      try repo.edit("Package.swift")
    }, filters: unitsAndSmoke),
  SelectionCase(
    name: "root Markdown and a Core source",
    change: { repo in
      try repo.append("README.md")
      try repo.edit("\(srcDir)/SwitchboardCore/Core.swift")
    }, filters: unitTargets),
  SelectionCase(
    name: "fixture that a suite names by its file name",
    files: [
      "Tests/IntegrationTests/FxStubUserTests.swift":
        "import Testing\n\nstruct FxStubUserTests {\n  @Test func runs() { #expect(\"claude-stub\".count > 0) }\n}\n",
      "Tests/IntegrationTests/FxStubLookalikeTests.swift":
        "import Testing\n\nstruct FxStubLookalikeTests {\n  @Test func runs() { #expect(\"claude-stub2\".count > 0) }\n}\n",
    ],
    listing: ["IntegrationTests.FxStubUserTests/runs()", "IntegrationTests.FxStubLookalikeTests/runs()"],
    change: { try $0.edit("Tests/IntegrationTests/Fixtures/claude-stub") },
    filters: unitsAndSmoke.union([suiteFilter("IntegrationTests", "FxStubUserTests")])),
  SelectionCase(
    name: "bin file that a suite names by its path",
    files: [
      "Tests/IntegrationTests/FxScriptTests.swift":
        "import Testing\n\nstruct FxScriptTests {\n  @Test func runs() { #expect(\"bin/other\".count > 0) }\n}\n",
      "Tests/IntegrationTests/FxOtherwiseTests.swift":
        "import Testing\n\nstruct FxOtherwiseTests {\n  @Test func runs() { #expect(\"bin/other-tool other\".count > 0) }\n}\n",
    ],
    listing: ["IntegrationTests.FxScriptTests/runs()", "IntegrationTests.FxOtherwiseTests/runs()"],
    change: { try $0.edit("bin/other") },
    filters: unitsAndSmoke.union([suiteFilter("IntegrationTests", "FxScriptTests")])),
]

private let rootMarkdownChanges: [(name: String, change: @Sendable (SelectionRepo) throws -> Void)] = [
  ("edited README.md", { try $0.edit("README.md") }),
  ("new CHANGELOG.md", { try $0.add("CHANGELOG.md", "# Changes\n") }),
  ("deleted README.md", { try $0.delete("README.md") }),
  (
    "two root Markdown files",
    { repo in
      try repo.append("README.md")
      try repo.add("CONTRIBUTING.md", "# Contributing\n")
    }
  ),
  ("untracked root Markdown", { try $0.write("NOTES.md", "# Notes\n") }),
]

private enum ChangeState: String, CaseIterable, Sendable {
  case committed, staged, unstaged
}

private struct PassthroughCase: Sendable, CustomTestStringConvertible {
  var args: [String]
  var invocations: [[String]]

  var testDescription: String { args.joined(separator: " ") }
}

private let testTargets = Set(unitTargetNames + ["IntegrationTests"])

/// A bin/test run with --filter arguments and the test bundles it should build.
private struct FilterCase: Sendable, CustomTestStringConvertible {
  var name: String
  var files: [String: String] = [:]
  var args: [String]
  var bundles: Set<String>

  var testDescription: String { name }
}

private let filterCases: [FilterCase] = [
  FilterCase(
    name: "a Core suite with its target prefix", args: ["--filter", "^SwitchboardCoreTests\\.FxCoreTests/"],
    bundles: ["SwitchboardCoreTests"]),
  FilterCase(
    name: "suites in parentheses, as bin/test prints them",
    args: ["--filter", "^SwitchboardCoreTests\\.(FxCoreTests|FxOtherTests)/"], bundles: ["SwitchboardCoreTests"]),
  FilterCase(name: "a Core suite name", args: ["--filter", "FxCoreTests"], bundles: ["SwitchboardCoreTests"]),
  FilterCase(name: "--filter=", args: ["--filter=FxAppTests"], bundles: ["SwitchboardAppTests"]),
  FilterCase(name: "an IntegrationTests suite", args: ["--filter", "FxCLITests"], bundles: ["IntegrationTests"]),
  FilterCase(
    name: "suites in two bundles", args: ["--filter", "FxCoreTests", "--filter", "FxServiceTests"],
    bundles: ["SwitchboardCoreTests", "SwitchboardServiceTests"]),
  FilterCase(
    name: "a name that two bundles' sources declare outside their file names",
    files: ["Tests/SwitchboardServiceTests/AdapterTests.swift": suiteFile("FxCoreAdapterTests", "adapts")],
    args: ["--filter", "FxCore"], bundles: ["SwitchboardCoreTests", "SwitchboardServiceTests"]),
  FilterCase(name: "part of a target's name", args: ["--filter", "Integration"], bundles: ["IntegrationTests"]),
  FilterCase(
    name: "a file name that no source names",
    files: ["Tests/SwitchboardAppTests/FxPlacement.swift": suiteFile("FxAppMoreTests", "places")],
    args: ["--filter", "FxPlacement"], bundles: ["SwitchboardAppTests"]),
  FilterCase(name: "--claude", args: ["--claude", "--filter", "FxCoreTests"], bundles: ["SwitchboardCoreTests"]),
]

/// Filters whose matches bin/test cannot place in known bundles, or whose matches
/// every bundle can hold.
private let everyBundleFilterArgs: [[String]] = [
  ["--filter", "Fx.*Tests"],
  ["--filter", "^SwitchboardCoreTests\\.FxCoreTests|FxServiceTests"],
  ["--filter", "^SwitchboardCoreTests\\.(FxCoreTests)|FxServiceTests"],
  ["--filter", "^SwitchboardCoreTests\\.FxCoreTests\\|FxServiceTests"],
  ["--filter", "Fx"],
  ["--filter", "^NoSuchTests\\.FxCoreTests"],
  ["--filter", "FxNoSuchSuite"],
  ["--filter", "FxCoreTests", "--filter", "Fx.*"],
]

/// Checks that bin/test built each of `bundles` in its own `--product` build, then ran
/// swift test once with `--skip-build`, the filters in `args`, and a `--skip` for each
/// other test target, whose bundle can predate the change.
private func expectFilteredBundles(
  _ run: SelectionRun, args: [String], bundles: Set<String>, sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(run.result.status == 0, "\(run.result.stderr)", sourceLocation: sourceLocation)
  #expect(run.builtProducts.sorted() == bundles.sorted(), "\(run.invocations)", sourceLocation: sourceLocation)
  #expect(run.testRuns.count == 1, "\(run.invocations)", sourceLocation: sourceLocation)
  guard let test = run.testRuns.first, let runIndex = run.invocations.firstIndex(of: test) else { return }
  expectProductBuildsBefore(run, runIndex, sourceLocation: sourceLocation)
  #expect(test.contains("--skip-build"), "\(test)", sourceLocation: sourceLocation)
  #expect(SelectionRun.filters(test) == SelectionRun.filters(args), "\(test)", sourceLocation: sourceLocation)
  #expect(
    Set(SelectionRun.skips(test)) == Set(testTargets.subtracting(bundles).map(wholeTarget)), "\(test)",
    sourceLocation: sourceLocation)
}

private struct SelectCase: Sendable, CustomTestStringConvertible {
  var name: String
  var files: [String: String] = [:]
  var paths: [String]
  var lines: Set<String>

  var testDescription: String { name }
}

private let smokeLine = "suites IntegrationTests 0 FxGroupTests FxRepoPathTests"

private let unitAndSmokeLines = Set(unitTargetNames.map { "target \($0)" } + [smokeLine])

/// The lines of `select_tests` output, with the names of each `suites` line sorted.
private func selectionLines(_ output: String) -> Set<String> {
  Set(
    output.split(separator: "\n").map { line in
      let words = line.split(separator: " ").map(String.init)
      guard words.first == "suites", words.count > 3 else { return words.joined(separator: " ") }
      return (words.prefix(3) + words.dropFirst(3).sorted()).joined(separator: " ")
    })
}

@Suite(.blocking(timeLimit: .seconds(60))) struct TestSelectionTests {
  @Test func allRunsSwiftTestWithNoFilterAndNoPackageDump() throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")

    let run = try repo.run("--all")

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.invocations == [["test"]])
  }

  @Test(arguments: sourceCases)
  fileprivate func aSourceChangeRunsTheTestTargetsThatDependOnItAndTheSourceReaders(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: suiteCases)
  fileprivate func aTestFileTheSelectorCanNarrowRunsOnlyItsSuites(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: listingFallbackCases)
  fileprivate func aListingWithFewerTestsThanTheFileRunsTheWholeTargetOrTheSmokeSuites(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: integrationFileCases)
  fileprivate func anIntegrationFileRunsTheSuitesThatUseItOrTheSmokeSuites(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: wholeTargetCases)
  fileprivate func aTestFileTheSelectorCannotNarrowRunsItsWholeTarget(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: unknownCases)
  fileprivate func aChangeOutsideSwiftTargetCodeRunsTheUnitTargetsAndTheSmokeSuites(_ c: SelectionCase) throws {
    try c.check()
  }

  @Test(arguments: rootMarkdownChanges.map { $0.name })
  func onlyRootMarkdownChangesRunNoTests(_ name: String) throws {
    let repo = try SelectionRepo()
    try #require(rootMarkdownChanges.first { $0.name == name }).change(repo)

    let run = try repo.run()

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.invocations == [["package", "dump-package"]], "\(run.invocations)")
    #expect(run.result.stderr.contains("bin/test --all runs every test"), "\(run.result.stderr)")
  }

  @Test func rootMarkdownBesideATestChangeRunsTheSuite() throws {
    let repo = try SelectionRepo()
    try repo.append("README.md")
    try repo.edit("Tests/SwitchboardAppTests/FxAppTests.swift")

    let run = try repo.run()

    expectTargeted(run, [suiteFilter("SwitchboardAppTests", "FxAppTests")])
  }

  @Test(arguments: ["exit 1", "echo not-json; exit 0"])
  func anUnreadablePackageRunsEveryTestOutsideIntegrationTests(_ dump: String) throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")
    repo.dumpPackage = dump

    let run = try repo.run()

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.testRuns == [["test", "--skip", wholeTarget("IntegrationTests")]], "\(run.invocations)")
    #expect(run.result.stderr.contains("could not read the package's targets"), "\(run.result.stderr)")
  }

  @Test func missingOriginMainRunsTheUnitTargetsAndTheSmokeSuites() throws {
    let repo = try SelectionRepo(originMain: false)
    try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")

    let run = try repo.run()

    expectTargeted(run, unitsAndSmoke)
  }

  @Test func originMainWithNoCommonHistoryRunsTheUnitTargetsAndTheSmokeSuites() throws {
    let repo = try SelectionRepo(originMain: false)
    let tree = try repo.git("hash-object", "-t", "tree", "-w", "/dev/null")
    let orphan = try repo.git("-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", tree, "-m", "orphan")
    try repo.git("update-ref", "refs/remotes/origin/main", orphan)
    try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")

    let run = try repo.run()

    expectTargeted(run, unitsAndSmoke)
  }

  /// origin/main moves past the merge base with a Package.swift change that
  /// the branch lacks. A diff against origin/main itself would show it.
  @Test func changesOnOriginMainAfterTheMergeBaseDoNotCount() throws {
    let repo = try SelectionRepo()
    try repo.git("switch", "-q", "-c", "side")
    try repo.edit("Package.swift")
    try repo.git("update-ref", "refs/remotes/origin/main", try repo.git("rev-parse", "HEAD"))
    try repo.git("switch", "-q", "main")
    try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")

    let run = try repo.run()

    expectTargeted(run, [suiteFilter("SwitchboardServiceTests", "FxServiceTests")])
  }

  @Test(arguments: ChangeState.allCases)
  fileprivate func aChangedTestFileCountsInEveryState(_ state: ChangeState) throws {
    let repo = try SelectionRepo()
    let path = "Tests/SwitchboardServiceTests/FxServiceTests.swift"
    try repo.append(path)
    switch state {
    case .committed: try repo.commit("edit")
    case .staged: try repo.git("add", path)
    case .unstaged: break
    }

    let run = try repo.run()

    expectTargeted(run, [suiteFilter("SwitchboardServiceTests", "FxServiceTests")])
  }

  /// The unstaged case leaves the new file untracked.
  @Test(arguments: ChangeState.allCases)
  fileprivate func aNewTestFileCountsInEveryState(_ state: ChangeState) throws {
    let repo = try SelectionRepo(listing: ["SwitchboardServiceTests.FxNewSuiteTests/works()"])
    let path = "Tests/SwitchboardServiceTests/FxNewSuiteTests.swift"
    try repo.write(path, suiteFile("FxNewSuiteTests", "works"))
    switch state {
    case .committed: try repo.commit("add")
    case .staged: try repo.git("add", path)
    case .unstaged: break
    }

    let run = try repo.run()

    expectTargeted(run, [suiteFilter("SwitchboardServiceTests", "FxNewSuiteTests")])
  }

  @Test func committedAndUncommittedChangesBothCount() throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardAppTests/FxAppTests.swift")
    try repo.append("Tests/SwitchboardServiceTests/FxServiceTests.swift")

    let run = try repo.run()

    expectTargeted(
      run, [suiteFilter("SwitchboardAppTests", "FxAppTests"), suiteFilter("SwitchboardServiceTests", "FxServiceTests")])
  }

  @Test func changedSelectsWhatNoArgumentsSelects() throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")

    let bare = try repo.run()
    let changed = try repo.run("--changed")

    expectTargeted(changed, [wholeTarget("SwitchboardAppTests"), sourceScanSuite])
    #expect(changed.testRuns == bare.testRuns)
  }

  @Test(arguments: [
    PassthroughCase(
      args: ["--filter", "FxCoreTests", "--parallel"], invocations: [["test", "--filter", "FxCoreTests", "--parallel"]]),
    PassthroughCase(
      args: ["--filter", "FxCoreTests", "--skip-build"],
      invocations: [["test", "--filter", "FxCoreTests", "--skip-build"]]),
    PassthroughCase(
      args: ["--filter", "FxCoreTests", "--skip", "Bar"],
      invocations: [["test", "--filter", "FxCoreTests", "--skip", "Bar"]]),
    PassthroughCase(args: ["--filter"], invocations: [["test", "--filter"]]),
    PassthroughCase(args: ["--skip", "Bar"], invocations: [["test", "--skip", "Bar"]]),
    PassthroughCase(args: ["--claude", "--filter", "Foo", "-v"], invocations: [["test", "--filter", "Foo", "-v"]]),
    PassthroughCase(
      args: ["--claude"], invocations: [["test", "--filter", "ClaudeTests"], ["test", "--skip", "ClaudeTests"]]),
  ])
  fileprivate func otherArgumentsPassThroughWithoutSelection(_ c: PassthroughCase) throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")

    let run = try repo.run(c.args)

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.invocations == c.invocations)
  }

  @Test func stderrNamesTheChangedPathAndTheSelectedTarget() throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")

    let run = try repo.run()

    #expect(run.result.stderr.contains("\(srcDir)/SwitchboardApp/App.swift"), "\(run.result.stderr)")
    #expect(run.result.stderr.contains("SwitchboardAppTests"), "\(run.result.stderr)")
  }

  @Test func aSourceChangeSaysItLeavesIntegrationTestsToCI() throws {
    let repo = try SelectionRepo()

    let r = try repo.select(["\(srcDir)/sb/main.swift"])

    #expect(r.stderr.contains("leaves IntegrationTests to CI"), "\(r.stderr)")
  }

  /// Every suite that the real Tests/smoke-suites lists is a type that a file
  /// of its target declares, so a renamed suite cannot drop out of the smoke run.
  @Test func eachRealSmokeSuiteExists() throws {
    let text = try String(
      contentsOf: Instance.root.appendingPathComponent("Tests/smoke-suites"), encoding: .utf8)
    let entries = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
    #expect(!entries.isEmpty)
    for entry in entries {
      let parts = entry.split(separator: ".")
      try #require(parts.count == 2, "\(entry)")
      let dir = Instance.root.appendingPathComponent("Tests/\(parts[0])")
      let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
      let declared = try files.contains { name in
        let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        return source.range(of: "(struct|class|enum|actor) \(parts[1])\\b", options: .regularExpression) != nil
      }
      #expect(declared, "\(entry)")
    }
  }

  @Test func aCoreTestEditBuildsOnlyTheCoreBundle() throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardCoreTests/FxCoreTests.swift")

    let run = try repo.run()

    expectTargeted(run, [suiteFilter("SwitchboardCoreTests", "FxCoreTests")])
    #expect(run.builtProducts == ["SwitchboardCoreTests"], "\(run.invocations)")
  }

  @Test func editsInTwoBundlesBuildBothAndNoOther() throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardCoreTests/FxCoreTests.swift")
    try repo.edit("Tests/SwitchboardServiceTests/FxServiceTests.swift")

    let run = try repo.run()

    expectTargeted(
      run,
      [suiteFilter("SwitchboardCoreTests", "FxCoreTests"), suiteFilter("SwitchboardServiceTests", "FxServiceTests")])
  }

  /// A suite filter that falls back to the smoke suites can name a target that the selection
  /// did not, so the run builds that target's bundle before it runs those suites.
  @Test func aSmokeSuiteInAnotherTargetGetsItsBundleBuilt() throws {
    let repo = try SelectionRepo(
      files: ["Tests/smoke-suites": "SwitchboardAppTests.FxAppTests\n"], listing: ["IntegrationTests.FxShapeTests/a()"])
    try repo.add(
      "Tests/IntegrationTests/FxShapeTests.swift",
      "import Testing\n\nstruct FxShapeTests {\n  @Test func a() {}\n}\n\nstruct FxOtherShapeTests {\n  @Test func a() {}\n}\n"
    )

    let run = try repo.run()

    expectTargeted(
      run,
      [
        suiteFilter("IntegrationTests", "FxShapeTests", "FxOtherShapeTests"),
        suiteFilter("SwitchboardAppTests", "FxAppTests"),
      ])
    #expect(run.builtProducts == ["IntegrationTests", "SwitchboardAppTests"], "\(run.invocations)")
  }

  /// swift test --skip-build fails when any test target's bundle is missing, as in
  /// a new worktree, so bin/test builds every bundle then.
  @Test func aMissingBundleBuildsEveryBundle() throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardCoreTests/FxCoreTests.swift")
    repo.bundles.removeAll { $0 == "IntegrationTests" }

    let run = try repo.run()

    expectBuiltEveryBundle(run, [suiteFilter("SwitchboardCoreTests", "FxCoreTests")])
  }

  /// SwiftPM's native build system, the default before Swift 6.4, makes one bundle
  /// for all test targets and no product for each, so bin/test builds every bundle.
  @Test func oneBundleForAllTestTargetsBuildsEveryBundle() throws {
    let repo = try SelectionRepo()
    try repo.edit("Tests/SwitchboardCoreTests/FxCoreTests.swift")
    repo.bundles = ["SwitchboardPackageTests"]

    let run = try repo.run()

    expectBuiltEveryBundle(run, [suiteFilter("SwitchboardCoreTests", "FxCoreTests")])
  }

  @Test func aFailingTargetedTestRunFailsBinTest() throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")
    repo.testStatus = 1

    let run = try repo.run()

    #expect(run.testRuns.count == 1, "\(run.invocations)")
    #expect(run.result.status != 0)
  }

  @Test func aFailingBuildFailsBinTestBeforeAnyTestRuns() throws {
    let repo = try SelectionRepo()
    try repo.edit("\(srcDir)/SwitchboardApp/App.swift")
    repo.buildStatus = 1

    let run = try repo.run()

    #expect(run.result.status != 0)
    #expect(run.testRuns.isEmpty, "\(run.invocations)")
  }

  @Test(arguments: filterCases)
  fileprivate func filtersBuildOnlyTheBundlesThatCanHoldTheirTests(_ c: FilterCase) throws {
    let repo = try SelectionRepo(files: c.files)

    let run = try repo.run(c.args)

    expectFilteredBundles(run, args: c.args, bundles: c.bundles)
  }

  /// The listing comes from the last build, which predates the new suite. Only the
  /// sources show that the filter also matches a suite in another bundle.
  @Test func aFilterMatchingASuiteNewSinceTheLastBuildBuildsItsBundle() throws {
    let repo = try SelectionRepo()
    try repo.write("Tests/SwitchboardAppTests/ViewTests.swift", suiteFile("FxCoreViewTests", "draws"))

    let run = try repo.run("--filter", "FxCore")

    expectFilteredBundles(run, args: ["--filter", "FxCore"], bundles: ["SwitchboardCoreTests", "SwitchboardAppTests"])
  }

  @Test(arguments: everyBundleFilterArgs)
  func filtersThatNeedEveryBundleRunPlainSwiftTest(_ args: [String]) throws {
    let repo = try SelectionRepo()

    let run = try repo.run(args)

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.builds.isEmpty, "\(run.invocations)")
    #expect(run.testRuns == [["test"] + args], "\(run.invocations)")
    #expect(run.result.stderr.contains("so every test bundle builds"), "\(run.result.stderr)")
  }

  @Test func anUnreadableSourceFileRunsPlainSwiftTest() throws {
    let repo = try SelectionRepo()
    let path = "\(repo.dir)/Tests/SwitchboardAppTests/FxAppTests.swift"
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    let run = try repo.run("--filter", "FxCoreTests")

    #expect(run.builds.isEmpty, "\(run.invocations)")
    #expect(run.testRuns == [["test", "--filter", "FxCoreTests"]], "\(run.invocations)")
  }

  @Test func aFilterWithAMissingBundleBuildsEveryBundleAndSkipsNone() throws {
    let repo = try SelectionRepo()
    repo.bundles.removeAll { $0 == "IntegrationTests" }

    let run = try repo.run("--filter", "FxCoreTests")

    #expect(run.result.status == 0, "\(run.result.stderr)")
    #expect(run.builds.map(\.args).filter { $0.contains("--build-tests") }.count == 1, "\(run.invocations)")
    #expect(run.builtProducts.isEmpty, "\(run.invocations)")
    #expect(run.testRuns.count == 1, "\(run.invocations)")
    let test = run.testRuns.first ?? []
    #expect(test.contains("--skip-build") && SelectionRun.skips(test).isEmpty, "\(test)")
  }

  @Test func aFailingFilteredBuildRunsNoTest() throws {
    let repo = try SelectionRepo()
    repo.buildStatus = 1

    let run = try repo.run("--filter", "FxCoreTests")

    #expect(run.result.status != 0)
    #expect(!run.builds.isEmpty, "\(run.invocations)")
    #expect(run.testRuns.isEmpty, "\(run.invocations)")
  }

  @Test(arguments: [
    SelectCase(name: "root Markdown", paths: ["README.md"], lines: []),
    SelectCase(name: "Package.swift", paths: ["Package.swift"], lines: unitAndSmokeLines),
    SelectCase(name: "fixture", paths: ["Tests/IntegrationTests/Fixtures/claude-stub"], lines: unitAndSmokeLines),
    SelectCase(
      name: "App source", paths: ["\(srcDir)/SwitchboardApp/App.swift"],
      lines: ["target SwitchboardAppTests", "suites SwitchboardServiceTests 1 FxSourceScanTests"]),
    SelectCase(
      name: "sb source", paths: ["\(srcDir)/sb/main.swift"],
      lines: ["suites SwitchboardServiceTests 1 FxSourceScanTests"]),
    SelectCase(
      name: "test file", paths: ["Tests/SwitchboardServiceTests/FxServiceTests.swift"],
      lines: ["suites SwitchboardServiceTests 2 FxServiceTests"]),
    SelectCase(
      name: "two suites",
      files: [
        "Tests/IntegrationTests/FxShapeTests.swift":
          "import Testing\n\nstruct FxShapeTests {\n  @Test func a() {}\n}\n\nstruct FxOtherShapeTests {\n  @Test func a() {}\n}\n"
      ],
      paths: ["Tests/IntegrationTests/FxShapeTests.swift"],
      lines: ["suites IntegrationTests 2 FxOtherShapeTests FxShapeTests"]),
    SelectCase(name: "helper", paths: ["Tests/IntegrationTests/Helpers.swift"], lines: [smokeLine]),
    SelectCase(
      name: "missing test file", paths: ["Tests/SwitchboardServiceTests/GoneTests.swift"],
      lines: ["target SwitchboardServiceTests"]),
  ])
  fileprivate func selectTestsPrintsOneLinePerSelection(_ c: SelectCase) throws {
    let repo = try SelectionRepo(files: c.files)

    let r = try repo.select(c.paths)

    #expect(r.status == 0, "\(r.stderr)")
    #expect(selectionLines(r.stdout) == c.lines, "\(r.stdout)")
  }

  @Test func selectTestsNamesEachPathOnStderr() throws {
    let repo = try SelectionRepo()
    let paths = ["README.md", "\(srcDir)/SwitchboardApp/App.swift"]

    let r = try repo.select(paths)

    #expect(r.status == 0, "\(r.stderr)")
    for path in paths { #expect(r.stderr.contains(path), "\(r.stderr)") }
  }
}
