import Foundation

/// The repo name that a list row shows in front of a session's reason.
public enum RepoLabels {
  /// A longer label keeps its end, which holds the repo's name.
  static let maxLength = 30

  /// Each session's label by session id. A session with no known repo, and
  /// the Manager, get none. When the sessions span fewer than two repos, no
  /// session gets one, because every row would say the same thing.
  public static func labels(_ sessions: [SessionSummary]) -> [String: String] {
    let listed = sessions.filter { $0.manager != true }
    var slugOfFolder: [String: String] = [:]
    for s in listed {
      if let folder = s.repo, let pr = s.pr, slugOfFolder[folder] == nil { slugOfFolder[folder] = pr.repo }
    }
    var repos: [Repo] = []
    var indexOfKey: [String: Int] = [:]
    var indexOf: [String: Int] = [:]
    for s in listed {
      let slug = if let folder = s.repo { slugOfFolder[folder] } else { s.pr?.repo ?? s.followup?.repository }
      guard let repo = Repo(folder: s.repo, slug: slug) else { continue }
      if indexOfKey[repo.key] == nil {
        indexOfKey[repo.key] = repos.count
        repos.append(repo)
      }
      indexOf[s.id] = indexOfKey[repo.key]
    }
    guard repos.count > 1 else { return [:] }

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
    return indexOf.mapValues { capped(repos[$0].label) }
  }

  static func capped(_ label: String) -> String {
    label.count <= maxLength ? label : "…" + label.suffix(maxLength - 1)
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
