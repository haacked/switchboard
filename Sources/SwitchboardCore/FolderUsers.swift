import Darwin
import Foundation

/// A process that has a folder open, and the path inside the folder that it has open.
public struct FolderUser: Sendable, Equatable {
  public var pid: Int
  public var path: String
}

extension Processes {
  /// The processes other than this one whose working folder, program, or an
  /// open file is `folder` or inside it. macOS lets a process read only its
  /// own user's processes, so the processes of root and of other users are
  /// left out. An empty list comes back when the folder doesn't exist,
  /// because its path can't be resolved.
  public static func using(_ folder: String) -> [FolderUser] {
    guard let resolved = realpath(folder, nil) else { return [] }
    let root = String(cString: resolved)
    free(resolved)
    let me = getpid()
    return allPids().filter { $0 != me }.compactMap { pid in
      firstPath(of: pid) { $0 == root || $0.hasPrefix(root + "/") }.map {
        FolderUser(pid: Int(pid), path: $0)
      }
    }
  }

  /// Every pid in `roots` and every process below them.
  public static func descendants(of roots: [Int], in children: [Int: [ProcessRow]]) -> Set<Int> {
    var found = Set(roots)
    var level = roots
    while !level.isEmpty {
      level = level.flatMap { children[$0] ?? [] }.map(\.pid).filter { found.insert($0).inserted }
    }
    return found
  }

  private static func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    // Processes can start between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return n > 0 ? pids.prefix(Int(n)).filter { $0 > 0 } : []
  }

  /// The process's working folder, program, or open file path that matches, checked in that order.
  private static func firstPath(of pid: pid_t, where matches: (String) -> Bool) -> String? {
    var vnodes = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodes, size) == size {
      let cwd = pathString(&vnodes.pvi_cdir.vip_path)
      if matches(cwd) { return cwd }
    }
    var program = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    if proc_pidpath(pid, &program, UInt32(program.count)) > 0 {
      let path = String(cString: program)
      if matches(path) { return path }
    }
    let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard listed > 0 else { return nil }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listed) / stride + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard got > 0 else { return nil }
    let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
      let path = pathString(&info.pvip.vip_path)
      if matches(path) { return path }
    }
    return nil
  }

  private static func pathString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
  }
}
