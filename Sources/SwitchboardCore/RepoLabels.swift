import Foundation

/// The repo name that a list row shows in front of a session's reason.
public enum RepoLabels {
  static let maxLength = 30

  /// Each session's label by session id. A session with no known repo, the
  /// Manager, and a group chat get none. When the sessions span fewer than two repos, no
  /// session gets one, because every row would say the same thing, unless
  /// `evenForOneRepo` is true, as for the merge board's lanes.
  public static func labels(_ sessions: [SessionSummary], evenForOneRepo: Bool = false) -> [String: String] {
    let listed = sessions.filter { $0.kind == .work }
    // Every session in a folder takes the owner/name of the first PR in that
    // folder, or else of the first started follow-up in it. A session's own PR
    // does not override it. The sessions in one folder therefore count as one repo.
    var slugOfFolder: [String: String] = [:]
    for s in listed {
      if let folder = s.repoFolder, let pr = s.pr, slugOfFolder[folder] == nil { slugOfFolder[folder] = pr.repo }
    }
    for s in listed {
      if let folder = s.repoFolder, let repository = s.followup?.repository, slugOfFolder[folder] == nil {
        slugOfFolder[folder] = repository
      }
    }
    var repos: [Repo] = []
    var indexOfKey: [String: Int] = [:]
    var repoIndexOfSession: [String: Int] = [:]
    for s in listed {
      let folder = s.repoFolder
      let slug = if let folder { slugOfFolder[folder] } else { s.pr?.repo ?? s.followup?.repository }
      guard let repo = Repo(folder: folder, slug: slug) else { continue }
      if indexOfKey[repo.key] == nil {
        indexOfKey[repo.key] = repos.count
        repos.append(repo)
      }
      repoIndexOfSession[s.id] = indexOfKey[repo.key]
    }
    guard repos.count > 1 || evenForOneRepo else { return [:] }

    // Repos that would show the same label move to their next longer form
    // until no two repos share a label or a repo has no longer form.
    var moved = true
    while moved {
      moved = false
      let holders = Dictionary(grouping: repos.indices) { repos[$0].label.lowercased() }
      for indices in holders.values where indices.count > 1 {
        for i in indices where repos[i].level < repos[i].forms.count - 1 {
          repos[i].level += 1
          moved = true
        }
      }
    }
    return repoIndexOfSession.mapValues { capped(repos[$0].label) }
  }

  /// A longer label keeps its first component. Collisions add components at
  /// the front, so the first component is the one that tells two repos apart.
  static func capped(_ label: String) -> String {
    func tail(_ s: Substring, _ n: Int) -> String { s.count <= n ? String(s) : "…" + s.suffix(n - 1) }
    guard label.count > maxLength else { return label }
    guard let slash = label.firstIndex(of: "/") else { return tail(label[...], maxLength) }
    var head = String(label[..<slash])
    if head.count > maxLength / 2 { head = head.prefix(maxLength / 2 - 1) + "…" }
    return head + "/" + tail(label[label.index(after: slash)...], maxLength - head.count - 1)
  }

  /// One repo and its labels, shortest first.
  struct Repo {
    var key: String
    var forms: [String]
    var level = 0
    var label: String { forms[level] }

    /// `slug` is the repo's `owner/name`, when it is known.
    init?(folder: String?, slug: String?) {
      if let slug {
        let short = folder.map { ($0 as NSString).lastPathComponent } ?? String(slug.split(separator: "/").last ?? "")
        key = "github:" + slug.lowercased()
        forms = [short, slug]
      } else if let folder {
        let parts = folder.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        key = "folder:" + parts.joined(separator: "/")
        forms = (1...parts.count).map { parts.suffix($0).joined(separator: "/") }
      } else {
        return nil
      }
    }
  }
}
