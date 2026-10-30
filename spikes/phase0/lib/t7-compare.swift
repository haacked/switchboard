import Foundation

/// Reads a t7-trunk.sh run folder and prints one tab-separated row for each
/// recorded `trunk merge status` output. A row holds what the timeline
/// parser read, how many timeline rows the output shows, and how many of
/// the parsed links hold a space, which a wrong join of a wrapped line
/// leaves. When the run also recorded the PR's comments with their times, the row adds the
/// state from Trunk's comments, whether both parsers say that Trunk holds
/// the PR, and where Trunk's comments sit among the PR's comments.
/// t7-trunk.sh compiles it together with SwitchboardCore's sources.
@main struct Compare {
  static func main() throws {
    let dir = CommandLine.arguments[1]
    let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".trunk.txt") }
    print(
      [
        "output", "trunk", "stack", "entries", "rows", "spaced_links", "trunk_ms", "pr_state", "comments", "agree",
        "comment_count", "status_from_start", "reply_from_end",
      ].joined(separator: "\t"))
    for file in files.sorted() {
      let name = String(file.dropLast(".trunk.txt".count))
      let output = try String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
      let meta = read("\(dir)/\(name).meta.json")
      // A looser pattern than the parser's, so the count checks the parser.
      let rows = TrunkTimeline.plainText(output).components(separatedBy: "\n").filter {
        $0.range(of: #"^\s*\d\d-\d\d \d\d:\d\d:\d\d"#, options: .regularExpression) != nil
      }
      var trunk = ""
      var parsed = ["", "", "", ""]
      var trunkQueued = false
      switch TrunkTimeline.parse(output, now: Int64(meta["start"]?.int ?? 0)) {
      case .found(let t):
        trunk = t.state?.rawValue ?? "no entries"
        let spaced = t.entries.filter { $0.text.range(of: #"\]\([^)\s]*\s"#, options: .regularExpression) != nil }
        parsed = [t.isStack ? "stack" : "", String(t.entries.count), String(rows.count), String(spaced.count)]
        trunkQueued = t.state?.isQueued ?? false
      case .notFound: trunk = "not found"
      case .notLoggedIn: trunk = "not logged in"
      case .unrecognized(let text): trunk = "unrecognized: \(oneLine(text, max: 60))"
      }
      var columns = [name, trunk] + parsed + [meta["ms"]?.int.map(String.init) ?? ""]
      let data = read("\(dir)/\(name).json")
      if let nodes = data["comments"]?.array, nodes.allSatisfy({ $0["createdAt"]?.string != nil }) {
        let comments = nodes.map { c in
          let login = c["author"]?["login"]?.string ?? ""
          let bot = c["author"]?["__typename"]?.string == "Bot"
          return PRComment(
            id: c["id"]?.string ?? "", author: bot ? "\(login)[bot]" : login, createdAt: c["createdAt"]?.string ?? "",
            editedAt: c["lastEditedAt"]?.string, edited: c["includesCreatedEdit"]?.bool ?? false,
            body: c["body"]?.string ?? "")
        }
        let prState = data["pr"]?["state"]?.string ?? ""
        let pr = PullRequest(id: "", number: 0, url: "", repo: "", state: PRState(rawValue: prState) ?? .open)
        let fromComments = TrunkComments.state(of: pr, comments)
        let commentsQueued = fromComments?.isQueued == true
        let fromTrunk = comments.indices.filter { comments[$0].author == TrunkComments.author }
        let status = fromTrunk.last { comments[$0].edited && TrunkComments.statusState(comments[$0].body ?? "") != nil }
        let reply = fromTrunk.last { !comments[$0].edited && TrunkComments.replyState(comments[$0].body ?? "") != nil }
        columns += [
          prState, fromComments?.rawValue ?? "none", trunkQueued == commentsQueued ? "yes" : "NO",
          String(comments.count),
          status.map { String($0) } ?? "", reply.map { String(comments.count - 1 - $0) } ?? "",
        ]
      }
      print(columns.joined(separator: "\t"))
    }
  }

  static func read(_ path: String) -> JSON {
    (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(JSON.parse) ?? .null
  }
}
