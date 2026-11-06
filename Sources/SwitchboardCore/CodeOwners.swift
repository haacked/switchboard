import Foundation

/// A CODEOWNERS file, read with the rules that GitHub documents. Each line
/// is a pattern and its owners. The last line that matches a path gives its
/// owners.
public struct CodeOwnersFile: Sendable {
  struct Line: @unchecked Sendable {
    /// NSRegularExpression is immutable and safe to share across threads.
    let pattern: NSRegularExpression
    let owners: [String]
  }

  let lines: [Line]

  /// nil when an active line uses syntax that GitHub does not support: a
  /// pattern that starts with `!`, holds `[`, `]`, or `\`, or is only
  /// slashes. sbd cannot predict how GitHub reads such a line.
  public static func parse(_ text: String) -> CodeOwnersFile? {
    var lines: [Line] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let pattern = tokens.first, !pattern.hasPrefix("#") else { continue }
      guard !pattern.hasPrefix("!"), !pattern.contains(where: "[]\\".contains),
        let regex = regex(pattern)
      else { return nil }
      lines.append(Line(pattern: regex, owners: Array(tokens.dropFirst().prefix { !$0.hasPrefix("#") })))
    }
    return CodeOwnersFile(lines: lines)
  }

  /// The owners of the last line that matches `path`. Empty when no line
  /// matches or the matching line names no owners.
  public func owners(of path: String) -> [String] {
    let range = NSRange(path.startIndex..., in: path)
    return lines.last { $0.pattern.firstMatch(in: path, range: range) != nil }?.owners ?? []
  }

  /// A pattern with a `/` before its end is anchored to the root. Any other
  /// pattern matches at any depth. A trailing `/` matches only below a
  /// directory. A last segment without a wildcard also matches everything
  /// below a directory of that name. A last segment with one matches only at
  /// its own level, as in GitHub's `docs/*` example. nil for a pattern that
  /// is only slashes.
  static func regex(_ pattern: String) -> NSRegularExpression? {
    var body = Substring(pattern)
    let rooted = body.hasPrefix("/")
    if rooted { body = body.dropFirst() }
    let directory = body.hasSuffix("/")
    if directory { body = body.dropLast() }
    guard !body.isEmpty else { return nil }
    let segments = body.split(separator: "/", omittingEmptySubsequences: false)
    var regex = rooted || segments.count > 1 ? "^" : "^(?:.*/)?"
    for (i, segment) in segments.enumerated() {
      let last = i == segments.count - 1
      if segment == "**" {
        regex += last ? ".+" : "(?:.*/)?"
        continue
      }
      // A run of asterisks inside a segment matches as one, as in gitignore.
      for (character, previous) in zip(segment, [nil] + segment.map(Optional.some)) {
        switch character {
        case "*": if previous != "*" { regex += "[^/]*" }
        case "?": regex += "[^/]"
        default: regex += NSRegularExpression.escapedPattern(for: String(character))
        }
      }
      if !last { regex += "/" }
    }
    let wildcard = segments.last!.contains { $0 == "*" || $0 == "?" }
    regex += directory ? "/.+$" : wildcard ? "$" : "(?:/.+)?$"
    return try? NSRegularExpression(pattern: regex)
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
  /// approved the PR while a group waits, when GitHub asked a code owner
  /// that no group names, and when the poll did not read the author or every
  /// code owner request.
  public init?(_ pr: PullRequest) {
    guard pr.state == .open, let requirement = pr.codeOwners, !requirement.groups.isEmpty,
      let author = pr.author?.lowercased(), let requests = pr.codeOwnerRequests
    else { return nil }
    let approvals = pr.verdicts.filter {
      $0.state == "APPROVED" && $0.commit == pr.headSha && $0.author.lowercased() != author
    }
    let approvers = Set(approvals.map { "@" + $0.author.lowercased() })
    let teams = Set(approvals.flatMap { $0.teams ?? [] }.map { "@" + $0.lowercased() })
    let groups = requirement.groups.sorted(by: CodeOwners.order).map { owners in
      CodeOwnerGroup(
        owners: owners,
        approved: owners.contains {
          let owner = $0.lowercased()
          return owner.contains("/") ? teams.contains(owner) : approvers.contains(owner)
        })
    }
    let satisfied = groups.allSatisfy(\.approved)
    let named = Set(groups.flatMap(\.owners).map { $0.lowercased() })
    guard pr.reviewDecision != .approved || satisfied, requests.allSatisfy({ named.contains($0.lowercased()) })
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
    var seen: Set<[String]> = []
    var groups: [[String]] = []
    for path in paths {
      let owners = file.owners(of: path).sorted { $0.lowercased() < $1.lowercased() }
      guard !owners.isEmpty, seen.insert(Array(Set(owners.map { $0.lowercased() })).sorted()).inserted else {
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
