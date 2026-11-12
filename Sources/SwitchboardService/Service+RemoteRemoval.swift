import Foundation
import SwitchboardCore

extension RemoteSite {
  /// Names the processes that use the folder `$1`, as `Processes.using` defines a use: a working folder, a
  /// program, or an open file that is the folder or inside it, checked in that order. An open directory is not a
  /// use, and neither is the working folder of ssh's background master. It reads the process table under `$2`
  /// when that is a folder, as on Linux, and otherwise runs the lsof that PATH finds. For each process it prints
  /// the pid, the use, and the path, then `done`, with a NUL after each. It exits 97 when it can't check.
  static let folderUsersScript = #"""
    found() { printf '%s\0%s\0%s\0' "$1" "$2" "$3"; }
    inside() {
      case $1 in "$root" | "$root"/*) return 0 ;; esac
      return 1
    }
    mux() {
      case $1 in "ssh: "*" [mux]"*) return 0 ;; esac
      return 1
    }
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
      printf 'done\0'
      exit 0
    fi
    root=$(cd -P -- "$1" 2>/dev/null && pwd -P && printf x) || {
      echo "it can't resolve $1" >&2
      exit 97
    }
    root=${root%?x}
    me=$$
    if [ -d "$2" ]; then
      for tool in readlink ls; do
        command -v "$tool" >/dev/null 2>&1 || {
          echo "it has no $tool" >&2
          exit 97
        }
      done
      for p in "$2"/[0-9]*; do
        pid=${p##*/}
        case $pid in '' | *[!0-9]*) continue ;; esac
        [ "$pid" = "$me" ] && continue
        cwd=$(readlink "$p/cwd" 2>/dev/null) || cwd=
        exe=$(readlink "$p/exe" 2>/dev/null) || exe=
        if [ -n "$cwd" ] && inside "$cwd"; then
          if [ "${exe##*/}" != ssh ] || ! mux "$(tr '\0' '\n' <"$p/cmdline" 2>/dev/null | head -n 1)"; then
            found "$pid" cwd "$cwd"
            continue
          fi
        fi
        if [ -n "$exe" ] && inside "$exe"; then
          found "$pid" program "$exe"
          continue
        fi
        links=$(ls -l "$p/fd/" 2>/dev/null) || continue
        while IFS= read -r line; do
          case $line in *" -> /"*) ;; *) continue ;; esac
          t=${line#*" -> "}
          if inside "$t" && [ ! -d "$t" ]; then
            found "$pid" 'open file' "$t"
            break
          fi
        done <<EOF
    $links
    EOF
      done
    elif command -v lsof >/dev/null 2>&1; then
      out=$(lsof -n -P -w -F pfn 2>/dev/null) || {
        echo "lsof failed" >&2
        exit 97
      }
      # The loop below reads only each process's first program line and the names inside the folder, because
      # the shell reads a line far slower than awk does.
      out=$(printf '%s\n' "$out" | SB_ROOT=$root awk '
        BEGIN { root = ENVIRON["SB_ROOT"] }
        /^p/ { print; first = 1; next }
        /^f/ { f = $0; next }
        /^n/ {
          n = substr($0, 2)
          txt = f == "ftxt"
          if (n == root || index(n, root "/") == 1 || (txt && first)) { print f; print }
          if (txt) first = 0
        }') || {
        echo "awk failed" >&2
        exit 97
      }
      pid= hit= cwd= prog= fd=
      flush() {
        if [ -z "$hit" ] && [ -n "$cwd" ]; then
          found "$pid" cwd "$cwd"
          hit=1
        fi
        cwd=
      }
      while IFS= read -r line; do
        case $line in
        p*)
          flush
          pid=${line#p} hit= prog= fd=
          [ "$pid" = "$me" ] && hit=1
          ;;
        f*) fd=${line#f} ;;
        n*)
          [ -n "$hit" ] && continue
          n=${line#n}
          case $fd in
          cwd) if inside "$n"; then cwd=$n; fi ;;
          txt)
            if [ -z "$prog" ]; then
              prog=$n
              if [ -n "$cwd" ]; then
                if [ "${prog##*/}" = ssh ] && mux "$(ps -o args= -p "$pid" 2>/dev/null)"; then
                  cwd=
                else
                  flush
                  continue
                fi
              fi
              if inside "$n"; then
                found "$pid" program "$n"
                hit=1
              fi
            elif inside "$n" && [ ! -d "$n" ]; then
              found "$pid" 'open file' "$n"
              hit=1
            fi
            ;;
          [0-9]*)
            flush
            if [ -z "$hit" ] && inside "$n" && [ ! -d "$n" ]; then
              found "$pid" 'open file' "$n"
              hit=1
            fi
            ;;
          esac
          ;;
        esac
      done <<EOF
    $out
    EOF
      flush
    else
      echo "it has neither /proc nor lsof" >&2
      exit 97
    fi
    printf 'done\0'
    """#

  /// The users in an answer of `folderUsersScript` that exited 0. It throws for an answer that does not end with
  /// `done`, which a cut answer does not, and for a field that it can't read.
  static func parseFolderUsers(_ answer: Data) throws -> [FolderUser] {
    let what = "the answer of the check of a folder's processes"
    guard answer.last == 0 else { throw APIError("\(what) is cut short") }
    var fields = try answer.dropLast().split(separator: 0, omittingEmptySubsequences: false).map {
      guard let text = String(data: Data($0), encoding: .utf8) else { throw APIError("\(what) is not text") }
      return text
    }
    guard fields.popLast() == "done", fields.count % 3 == 0 else { throw APIError("\(what) is cut short") }
    return try stride(from: 0, to: fields.count, by: 3).map { i in
      guard let pid = Int(fields[i]), let use = FolderUse(rawValue: fields[i + 1]) else {
        throw APIError("\(what) holds \"\(fields[i])\" and \"\(fields[i + 1])\"")
      }
      return FolderUser(pid: pid, use: use, path: fields[i + 2])
    }
  }

  /// Removes the folder `$1` with `rm -rf` when its parent and its parent's parent are folders and not links. It
  /// exits 4, and removes nothing, when one of them is a link or another kind of file. It exits 0 when one is gone.
  static let sessionFolderRemoval = #"""
    sessions=${1%/*}
    for d in "${sessions%/*}" "$sessions"; do
      if [ -L "$d" ]; then
        printf '%s is a link, so sbd removed nothing\n' "$d" >&2
        exit 4
      fi
      [ -e "$d" ] || exit 0
      if [ ! -d "$d" ]; then
        printf '%s is not a folder, so sbd removed nothing\n' "$d" >&2
        exit 4
      fi
    done
    exec /bin/rm -rf -- "$1"
    """#

  /// Removes the session's launcher folder on the host with `rm -rf`. It refuses, and removes nothing, unless
  /// `id` is `s` followed by lowercase letters and digits, `path` is `<home>/.sb/sessions/<id>` of the current
  /// connection, and `.sb` and `.sb/sessions` are folders and not links. A folder that is already gone is no
  /// error.
  func removeSessionFolder(_ path: String, of id: String) throws {
    let host = hostName ?? "the host"
    let tail = id.utf8.dropFirst()
    guard id.utf8.first == UInt8(ascii: "s"), !tail.isEmpty,
      tail.allSatisfy({
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
      })
    else {
      throw APIError("\"\(id)\" is not a session id, so sbd removed no folder on \(host)")
    }
    try confirmed("the removal of \(path)") { machine in
      // String equality would match a path whose bytes differ, such as another Unicode normalization of it.
      guard try Array(path.utf8) == Array(sessionFolder(id).utf8) else {
        throw APIError("\(path) is not the launcher folder of \(id), so sbd removed no folder on \(host)")
      }
      let r = try machine.run(
        "/bin/sh", ["-c", Self.sessionFolderRemoval, "sb", path], env: nil, input: nil, timeout: Self.commandSeconds)
      guard r.status == 0 else { throw APIError("rm -rf \(path) on \(host): \(r.problem)") }
    }
  }
}

extension Service {
  /// Removes a session whose host config.json no longer lists. sbd can't reach that host, so it contacts nothing
  /// and runs nothing for the session. It forgets a session whose claude stopped on record and refuses one whose
  /// claude may still run there, and it refuses a removal of the worktree.
  func removeFromUnlistedHost(
    _ session: Session, resolving: Set<String>, worktree: Bool, mayRunClaude: Bool, site: any SessionSite
  ) throws -> JSON {
    let host = session.host ?? "its host"
    if worktree { try site.requireReady() }
    if mayRunClaude {
      throw APIError(
        "\(session.id)'s claude may still run on \(host), which \(home.config) no longer lists, so sbd can't stop it. List \(host) there again to remove \(session.id)."
      )
    }
    try queue.sync {
      guard entries[session.id]?.session.cwd == session.cwd, !starting.contains(session.id),
        !merging.contains(session.id)
      else {
        throw APIError("\(session.id) changed while it was being removed")
      }
      guard let entry = entries[session.id], !self.mayRunClaude(entry) else {
        throw APIError("\(session.id)'s claude may still run on \(host), so sbd can't remove it.")
      }
      try forgetSession(session.id, resolving: resolving)
      try detachPlans { $0.session == session.id }
    }
    return [
      "removed": .string(session.id), "worktree_removed": false, "branch_removed": false,
      "remote_branch_removed": false,
    ]
  }

  /// A fresh read of the panes and processes at the session's site, which a removal installs before it stops
  /// anything. On a host, it throws when the read got no answer.
  func freshSnapshot(of session: Session) throws -> Snapshot? {
    guard let host = session.host else { return buildSnapshot() }
    return try readSnapshot(onHost: host)
  }

  /// Installs a snapshot from `freshSnapshot(of:)`. It runs on the state queue.
  func install(_ snapshot: Snapshot?, of session: Session) {
    guard let host = session.host else { return install(snapshot) }
    install(snapshot, onHost: host)
  }

  /// Stops the session's claude before a removal that keeps the worktree. On a host, it refuses while the
  /// session's claude state is unknown, signals claude through the checked kill, and closes both panes from
  /// answers of the host, so the session is never forgotten while its claude may still run there. It runs on the
  /// state queue.
  func stopForRemoval(_ session: Session, at site: any SessionSite) throws {
    try requireRead(session.id)
    if case .running(let pid) = claudeState(session.id) { try stopClaude(session.id, pid) }
    guard session.host != nil else { return }
    for pane in [Pane.claude, .shell] { try closePane(session.id, pane, at: site) }
  }

  /// Removes the launcher folder of a session that sbd forgot. A failure leaves the folder, which nothing
  /// reads once the session is gone.
  func removeSessionFolder(_ id: String, at site: any SessionSite) {
    if let remote = site as? RemoteSite {
      do {
        try remote.removeSessionFolder(try remote.sessionFolder(id), of: id)
      } catch {
        logLine("can't remove the launcher folder of \(id) on \(remote.hostName ?? "its host"): \(error)")
      }
    } else if site.hostName == nil, let folder = try? site.sessionFolder(id) {
      // FileManager deletes on this Mac, so only this Mac's site names a folder for it.
      try? FileManager.default.removeItem(atPath: folder)
    }
  }

  /// Whether the folder is gone at the site. On a host, only the host's answer that the path does not exist
  /// counts, so a check that got no answer or could not search the path never reads as gone.
  func folderIsGone(_ path: String, at site: any SessionSite) throws -> Bool {
    guard site.hostName != nil else { return !site.machine.exists(path) }
    return try site.folderGone(path)
  }

  /// The PR when it may stand for the session's work. On this Mac, that is the PR that sbd holds. A host can
  /// name any PR in its transcript, so on a host the PR counts only when git in `dir` there pushes the
  /// session's branch to the PR's head branch in the PR's repo, as the poller's lookup by branch finds a PR.
  /// It returns nil when git can't show that.
  func provenPR(
    _ pr: PullRequest?, of session: Session, in dir: String, at site: any SessionSite
  ) throws -> PullRequest? {
    guard site.hostName != nil, let pr else { return pr }
    guard let branch = session.branch,
      let common = try? gitOutput(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: site)
    else { return nil }
    // `--get-regexp` exits 1 when no key matches.
    let listed = try site.machine.run(site.git(), ["-C", dir, "config", "--get-regexp", GitHubPoller.branchKeyConfig])
    guard listed.status == 0 || listed.status == 1 else { return nil }
    let key = GitHub.branchKey(branch: branch, config: GitHub.gitConfig(listed.stdout)) { remote in
      site.machine.text("\(common)/refs/remotes/\(remote)/HEAD").flatMap {
        GitHub.branch(head: $0, under: "refs/remotes/\(remote)/")
      }
    }
    guard case .branch(let repo, let head, _) = key, repo.lowercased() == pr.repo.lowercased(), head == pr.head
    else { return nil }
    return pr
  }

  /// Whether git at the site answers that the branch does not exist. On a host, any status but git's yes or no
  /// throws, so a check that got no answer never reads as gone.
  func branchIsGone(_ repo: String, _ branch: String, at site: any SessionSite) throws -> Bool {
    guard site.hostName != nil else { return !branchExists(repo, branch, at: site) }
    let r = try site.machine.run(site.git(), ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
    switch r.status {
    case 0: return false
    case 1: return true
    default: throw APIError("git can't tell whether \(branch) exists: exit status \(r.status)")
    }
  }
}
