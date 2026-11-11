import Foundation
import SwitchboardCore

extension Service {
  /// The real path of the main checkout of the git repository that holds `path`. A linked worktree, a
  /// subfolder, and a symlink all give that one path, so it identifies the repository.
  ///
  /// It throws unless `path` is an absolute folder in a git repository whose main checkout exists and has
  /// a working tree. It runs git, so it runs off the state queue.
  func mainCheckout(of path: String) throws -> String {
    let folder = (path.expandingTilde as NSString).standardizingPath
    guard folder.hasPrefix("/"), isDirectory(folder) else { throw APIError("no folder \(path)") }
    // The first worktree that git lists is the main checkout.
    guard let main = (try? worktreeEntries(folder))?.first?.path else {
      throw APIError("\(path) isn't in a git repository")
    }
    // A bare repository lists itself first and has no working tree.
    if (try? gitOutput(main, ["rev-parse", "--is-bare-repository"])) == "true" {
      throw APIError("\(path) is in a bare repository, which has no checkout to run in")
    }
    // A repository whose git folder is outside its checkout lists that git folder first.
    guard let top = try? gitOutput(main, ["rev-parse", "--show-toplevel"]), samePath(top, main),
      let real = realPath(main)
    else { throw APIError("the main checkout of \(path) is gone: \(main)") }
    return real
  }

  /// The repositories that the New Session sheet offers: the main checkout of each work session, the
  /// remembered ones, and the ones under `repos` in config.json. A candidate whose folder no longer
  /// resolves to a main checkout is left out.
  func knownRepos() throws -> [KnownRepo] {
    let candidates: [(folder: String, used: Int64?)] = try queue.sync {
      let sessions = entries.values.map(\.session).filter { $0.kind == .work && !$0.cwd.isEmpty }
      return sessions.map { (checkout($0) ?? $0.cwd, $0.created) }
        + (try store.knownRepos()).map { ($0.path, $0.used) }
        + config.repos.values.map { ($0, nil) }
    }
    let folders = Array(Set(candidates.map(\.folder)))
    let mains = Dictionary(
      uniqueKeysWithValues: zip(folders, concurrentMap(folders) { try? self.mainCheckout(of: $0) })
    ).compactMapValues { $0 }
    let paths = Array(Set(mains.values))
    let names = Dictionary(uniqueKeysWithValues: zip(paths, concurrentMap(paths, repoName)))
    return KnownRepos.merge(
      candidates.compactMap { candidate in
        guard let path = mains[candidate.folder], let name = names[path] else { return nil }
        return KnownRepo(path: path, name: name, used: candidate.used)
      })
  }

  /// Validates the folder, remembers its repository as used now, and returns its entry.
  func addRepo(_ args: JSON) throws -> KnownRepo {
    guard let path = args["path"]?.string else { throw APIError("repo-add needs a path") }
    let main = try mainCheckout(of: path)
    let used = nowMs()
    try queue.sync { try store.remember(repo: main, used: used) }
    return KnownRepo(path: main, name: repoName(main), used: used)
  }

  /// Remembers the repository of a new session's folder as used at `used`. A session may run outside git,
  /// so a folder with no repository is not an error. `new` passes the session's creation time, so the
  /// entry keeps its place in the list when the session is removed.
  func rememberRepo(_ folder: (cwd: String, branch: String?, repo: String?), used: Int64) {
    // `prepareFolder` sets `repo` only to a main checkout it has already resolved.
    guard let main = folder.repo.flatMap(realPath) ?? (try? mainCheckout(of: folder.cwd)) else { return }
    queue.sync { try? store.remember(repo: main, used: used) }
  }

  private func repoName(_ path: String) -> String {
    githubRepository(path) ?? (path as NSString).lastPathComponent
  }
}
