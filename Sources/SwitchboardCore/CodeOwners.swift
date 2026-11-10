import Foundation

/// A CODEOWNERS file, read with the rules that GitHub documents. Each line
/// is a pattern and its owners. The last line that matches a path gives its
/// owners.
public struct CodeOwnersFile: Sendable {
  /// One step of a pattern, matched against a path's `/`-separated segments.
  enum Step: Equatable, Sendable {
    /// One segment that matches a glob, where `*` matches any run of
    /// characters and `?` matches one.
    case segment([Character])
    /// Any number of whole segments, including none.
    case anySegments
    /// One or more whole segments.
    case someSegments
  }

  struct Line: Sendable {
    let steps: [Step]
    let owners: [String]
  }

  let lines: [Line]

  /// Counts the patterns that `steps(_:)` compiles on the current task. A
  /// test binds it to show that matching reuses the steps that `parse` built.
  /// It is unchecked because only the task that binds it parses and matches.
  final class Compilations: @unchecked Sendable {
    var count = 0
  }

  @TaskLocal static var compilations: Compilations?

  /// nil when an active line uses syntax that GitHub does not support: a
  /// pattern that starts with `!`, holds `[`, `]`, or `\`, or is only
  /// slashes. sbd cannot predict how GitHub reads such a line.
  public static func parse(_ text: String) -> CodeOwnersFile? {
    var lines: [Line] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let pattern = tokens.first, !pattern.hasPrefix("#") else { continue }
      guard !pattern.hasPrefix("!"), !pattern.contains(where: "[]\\".contains),
        let steps = steps(pattern)
      else { return nil }
      lines.append(Line(steps: steps, owners: Array(tokens.dropFirst().prefix { !$0.hasPrefix("#") })))
    }
    return CodeOwnersFile(lines: lines)
  }

  /// The owners of the last line that matches `path`. Empty when no line
  /// matches or the matching line names no owners.
  public func owners(of path: String) -> [String] {
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(Array.init)
    return lines.last { Self.matches($0.steps, segments) }?.owners ?? []
  }

  /// A pattern with a `/` before its end is anchored to the root. Any other
  /// pattern matches at any depth. A trailing `/` matches only below a
  /// directory. A last segment without a wildcard also matches everything
  /// below a directory of that name. A last segment with one matches only at
  /// its own level, as in GitHub's `docs/*` example. nil for a pattern that
  /// is only slashes.
  static func steps(_ pattern: String) -> [Step]? {
    compilations?.count += 1
    var body = Substring(pattern)
    let rooted = body.hasPrefix("/")
    if rooted { body = body.dropFirst() }
    let directory = body.hasSuffix("/")
    if directory { body = body.dropLast() }
    guard !body.isEmpty else { return nil }
    let segments = body.split(separator: "/", omittingEmptySubsequences: false)
    var steps: [Step] = rooted || segments.count > 1 ? [] : [.anySegments]
    for (i, segment) in segments.enumerated() {
      if segment == "**" {
        steps.append(i == segments.count - 1 ? .someSegments : .anySegments)
      } else {
        steps.append(.segment(Array(segment)))
      }
    }
    if directory {
      steps.append(.someSegments)
    } else if !segments.last!.contains(where: "*?".contains) {
      steps.append(.anySegments)
    }
    return steps
  }

  /// Matches with a table over (step, segment) pairs, in time proportional
  /// to their product. The repository writes the CODEOWNERS lines. A
  /// backtracking regex runs for minutes on a line with many wildcards.
  static func matches(_ steps: [Step], _ segments: [[Character]]) -> Bool {
    // `rest[j]` is whether the steps after the current one match `segments[j...]`.
    var rest = [Bool](repeating: false, count: segments.count + 1)
    rest[segments.count] = true
    for step in steps.reversed() {
      var next = [Bool](repeating: false, count: segments.count + 1)
      for j in stride(from: segments.count, through: 0, by: -1) {
        switch step {
        case .segment(let glob): next[j] = j < segments.count && rest[j + 1] && Self.glob(glob, segments[j])
        case .anySegments: next[j] = rest[j] || (j < segments.count && next[j + 1])
        case .someSegments: next[j] = j < segments.count && (rest[j + 1] || next[j + 1])
        }
      }
      rest = next
    }
    return rest[0]
  }

  /// Matches one segment against a glob in time proportional to their
  /// lengths' product. It returns to the most recent `*` on a mismatch.
  static func glob(_ glob: [Character], _ text: [Character]) -> Bool {
    var g = 0
    var t = 0
    var star: (g: Int, t: Int)?
    while t < text.count {
      if g < glob.count, glob[g] == "*" {
        star = (g, t)
        g += 1
      } else if g < glob.count, glob[g] == "?" || glob[g] == text[t] {
        g += 1
        t += 1
      } else if let last = star {
        g = last.g + 1
        t = last.t + 1
        star = (last.g, last.t + 1)
      } else {
        return false
      }
    }
    while g < glob.count, glob[g] == "*" { g += 1 }
    return g == glob.count
  }
}

/// Whether the base branch requires code owner review. `on` carries the
/// file that names the owners. `off` carries why GitHub's requirement is
/// absent or unknown to sbd. Both show no shield.
public enum CodeOwnersConfig: Sendable {
  case off(String)
  case on(CodeOwnersFile)
}

/// The code owner groups that a PR's changed files need, as CODEOWNERS
/// spells the owners. Each group is one line's owners. Any one of them
/// approves the group.
public struct CodeOwnerRequirement: Codable, Equatable, Sendable {
  public var groups: [[String]]

  public init(groups: [[String]]) {
    self.groups = groups
  }
}

/// One owner group and whether one of its owners approved the PR's head.
public struct CodeOwnerGroup: Codable, Equatable, Sendable {
  public var owners: [String]
  public var approved: Bool

  public init(owners: [String], approved: Bool) {
    self.owners = owners
    self.approved = approved
  }
}

/// What a PR's tiles show about its code owner review.
public struct CodeOwnerStatus: Codable, Equatable, Sendable {
  /// Every group approved.
  public var satisfied: Bool
  public var groups: [CodeOwnerGroup]

  public init(satisfied: Bool, groups: [CodeOwnerGroup]) {
    self.satisfied = satisfied
    self.groups = groups
  }

  /// The status of an open PR with a requirement. A group is approved by an
  /// APPROVED last verdict on the head commit from someone other than the
  /// PR's author. A user owner approves by their login. A team owner
  /// approves through a team that the review was on behalf of. nil when sbd
  /// cannot show that its view equals GitHub's. That holds when GitHub
  /// approved the PR while a group waits, when a waiting group has an owner
  /// whose approval is on an older commit, when GitHub asked a code owner
  /// that no group names, and when the poll did not read the author or every
  /// code owner request. GitHub keeps an older commit's approval on a base
  /// that keeps stale reviews, and sbd does not read that setting.
  public init?(_ pr: PullRequest) {
    guard pr.state == .open, let requirement = pr.codeOwners, !requirement.groups.isEmpty,
      let author = pr.author?.lowercased(), let requests = pr.codeOwnerRequests
    else { return nil }
    let approvals = pr.verdicts.filter { $0.state == "APPROVED" && $0.author.lowercased() != author }
    // A login has no slash and a team slug has one, so one set holds both kinds of owner.
    func approvers(_ verdicts: [Review]) -> Set<String> {
      Set(verdicts.flatMap { ["@" + $0.author] + ($0.teams ?? []).map { "@" + $0 } }.map { $0.lowercased() })
    }
    let current = approvers(approvals.filter { $0.commit == pr.headSha })
    let older = approvers(approvals.filter { $0.commit != pr.headSha })
    let groups = requirement.groups.sorted(by: CodeOwners.order).map { owners in
      CodeOwnerGroup(owners: owners, approved: owners.contains { current.contains($0.lowercased()) })
    }
    let satisfied = groups.allSatisfy(\.approved)
    let named = Set(groups.flatMap(\.owners).map { $0.lowercased() })
    let olderApprovalWaits = groups.contains { group in
      !group.approved && group.owners.contains { older.contains($0.lowercased()) }
    }
    guard pr.reviewDecision != .approved || satisfied, !olderApprovalWaits,
      requests.allSatisfy({ named.contains($0.lowercased()) })
    else { return nil }
    self.init(satisfied: satisfied, groups: groups)
  }

  /// The status in words. `separator` joins its lines. One group takes one
  /// line. Several take a count, then a line for each group.
  public func text(separator: String) -> String {
    let approved = groups.filter(\.approved).count
    let word = satisfied ? "approved" : "required"
    let names = { (group: CodeOwnerGroup) in group.owners.joined(separator: " or ") }
    if groups.count == 1 { return "Code owner review \(word): \(names(groups[0]))" }
    let count = satisfied ? "\(approved) of \(groups.count)" : "\(approved) of \(groups.count) approved"
    return
      (["Code owner review \(word) (\(count))"]
      + groups.map { "\(names($0)): \($0.approved ? "approved" : "waiting")" })
      .joined(separator: separator)
  }
}

public enum CodeOwners {
  /// The most changed files that sbd reads for one PR. A larger PR has no
  /// known requirement.
  public static let maxFiles = 1000

  /// The groups that a PR's changed files need. `total` is GitHub's count of
  /// changed files. nil when the config is off, no file has an owner, the
  /// paths are not every changed file, or there are more than `maxFiles`.
  /// Also nil when a group names an email address. sbd cannot match an email
  /// address to a reviewer.
  public static func requirement(_ config: CodeOwnersConfig, paths: [String], total: Int) -> CodeOwnerRequirement? {
    guard case .on(let file) = config, total <= maxFiles, paths.count == total else { return nil }
    var seen: Set<Set<String>> = []
    var groups: [[String]] = []
    for path in paths {
      let owners = file.owners(of: path).sorted { $0.lowercased() < $1.lowercased() }
      guard !owners.isEmpty, seen.insert(Set(owners.map { $0.lowercased() })).inserted else {
        continue
      }
      guard owners.allSatisfy({ $0.hasPrefix("@") }) else { return nil }
      groups.append(owners)
    }
    return groups.isEmpty ? nil : CodeOwnerRequirement(groups: groups.sorted(by: order))
  }

  /// Groups in order of their owners, compared case-insensitively.
  static func order(_ a: [String], _ b: [String]) -> Bool {
    a.lexicographicallyPrecedes(b) { $0.lowercased() < $1.lowercased() }
  }
}
