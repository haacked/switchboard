import Foundation

/// One page of one source that an issues query reads.
public struct IssuePageRequest: Equatable, Sendable {
  public var source: IssueSource
  /// Updates since this ISO 8601 time, in any state, or nil to read the open issues.
  public var since: String?
  /// The cursor of the page to read, or nil for the first page.
  public var after: String?

  public init(source: IssueSource, since: String? = nil, after: String? = nil) {
    self.source = source
    self.since = since
    self.after = after
  }

  /// A full read asks for 100 issues a page. An incremental read asks for 25, because GitHub prices a query by the
  /// page sizes it asks for, not by the rows it returns.
  public var first: Int { since == nil ? 100 : 25 }
}

/// What an issues query read for one source.
public struct IssuePage: Equatable, Sendable {
  public var issues: [InboxIssue]
  /// The cursor of the next page, while one is left.
  public var next: String?
  /// Why GitHub answered nothing for the source, such as a repository that is missing or unreadable.
  public var error: String?

  public init(issues: [InboxIssue], next: String? = nil, error: String? = nil) {
    self.issues = issues
    self.next = next
    self.error = error
  }
}

extension GitHub {
  /// The labels and assignees past the first 10 and 5 are left out, because each one raises the query's price.
  static let issueFields = """
    fragment issue on Issue {
      number title url body state createdAt updatedAt repository { nameWithOwner } author { login }
      labels(first: 10) { nodes { name } }
      assignees(first: 5) { nodes { login } }
    }
    """

  /// One query that reads each request's page as an alias, `r<i>` for a repository and `o<i>` for an org's search,
  /// with the viewer's login and the query's cost.
  public static func issuesQuery(_ requests: [IssuePageRequest]) -> (query: String, variables: JSON) {
    var params: [String] = []
    var fields: [String] = []
    var variables: [String: JSON] = [:]
    for (i, request) in requests.enumerated() {
      let page = "first: \(request.first), after: $a\(i)"
      params.append("$a\(i): String")
      variables["a\(i)"] = request.after.map(JSON.string) ?? .null
      let source = request.source
      if source.isOrg {
        params.append("$q\(i): String!")
        variables["q\(i)"] = .string(searchText(source, since: request.since))
        fields.append(
          "o\(i): search(type: ISSUE, \(page), query: $q\(i)) { pageInfo { hasNextPage endCursor } nodes { ...issue } }"
        )
      } else {
        let (owner, name) = ownerAndName(source.name)
        params += ["$o\(i): String!", "$n\(i): String!"]
        variables["o\(i)"] = .string(owner)
        variables["n\(i)"] = .string(name)
        var filters = ["states: [OPEN]"]
        if let since = request.since {
          params.append("$s\(i): DateTime")
          variables["s\(i)"] = .string(since)
          filters = ["since: $s\(i)"]
        }
        if let label = source.label {
          params.append("$l\(i): [String!]")
          variables["l\(i)"] = .array([.string(label)])
          filters.append("labels: $l\(i)")
        }
        if let person = source.person {
          params.append("$p\(i): String")
          variables["p\(i)"] = .string(person)
          filters.append("assignee: $p\(i)")
        }
        fields.append(
          "r\(i): repository(owner: $o\(i), name: $n\(i)) { issues(\(page), filterBy: {\(filters.joined(separator: ", "))}, "
            + "orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { ...issue } } }"
        )
      }
    }
    let header = params.isEmpty ? "query" : "query(\(params.joined(separator: ", ")))"
    let query = """
      \(header) {
        rateLimit { cost }
        viewer { login }
        \(fields.joined(separator: "\n  "))
      }
      \(issueFields)
      """
    return (query, .object(variables))
  }

  /// The search text of an org source. Without `since` it reads open issues. With it, it reads every issue updated
  /// since then, so a closed one arrives once and leaves the cache.
  public static func searchText(_ source: IssueSource, since: String?) -> String {
    var terms = ["org:\(source.name)", "is:issue"]
    if let label = source.label { terms.append("label:\"\(label.replacingOccurrences(of: "\"", with: ""))\"") }
    if let person = source.person { terms.append("assignee:\(person)") }
    if let since { terms.append("updated:>=\(since)") } else { terms.append("is:open") }
    return terms.joined(separator: " ")
  }

  /// Each request's page from an issues query's `data`, in request order, and the viewer's login.
  public static func parseIssues(_ data: JSON, _ requests: [IssuePageRequest]) -> (
    viewer: String?, pages: [IssuePage]
  ) {
    let pages = requests.enumerated().map { i, request -> IssuePage in
      let connection: JSON?
      if request.source.isOrg {
        connection = data["o\(i)"]
      } else {
        guard let repo = data["r\(i)"], repo != .null else {
          return IssuePage(
            issues: [], error: "can't read \(request.source.name). It is missing or the token can't see it.")
        }
        connection = repo["issues"]
      }
      guard let connection, connection != .null else {
        return IssuePage(issues: [], error: "GitHub answered nothing for \(request.source.key)")
      }
      let issues = nodes(connection).compactMap(parseIssue)
      let more = connection["pageInfo"]?["hasNextPage"]?.bool == true
      return IssuePage(issues: issues, next: more ? connection["pageInfo"]?["endCursor"]?.string : nil)
    }
    return (data["viewer"]?["login"]?.string, pages)
  }

  /// A search node that is not an issue, such as a PR, has no `number` and gives nil.
  static func parseIssue(_ node: JSON) -> InboxIssue? {
    guard let number = node["number"]?.int, let repo = node["repository"]?["nameWithOwner"]?.string,
      let title = node["title"]?.string, let url = node["url"]?.string
    else { return nil }
    return InboxIssue(
      repo: repo, number: number, title: title, url: url, body: node["body"]?.string ?? "",
      state: node["state"]?.string == "OPEN" ? .open : .closed,
      labels: nodes(node["labels"]).compactMap { $0["name"]?.string },
      assignees: nodes(node["assignees"]).compactMap { $0["login"]?.string }, author: node["author"]?["login"]?.string,
      createdAt: node["createdAt"]?.string ?? "", updatedAt: node["updatedAt"]?.string ?? "")
  }
}
