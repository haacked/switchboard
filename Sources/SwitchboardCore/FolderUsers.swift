import Darwin
import Foundation

/// How a process uses a folder.
public enum FolderUse: String, Sendable {
  case workingFolder = "cwd"
  case program
  case openFile = "open file"
}

/// A process that uses a folder, how it uses it, and the path inside the folder that it uses.
public struct FolderUser: Sendable, Equatable {
  public var pid: Int
  public var use: FolderUse
  public var path: String

  public init(pid: Int, use: FolderUse, path: String) {
    self.pid = pid
    self.use = use
    self.path = path
  }
}

/// The path with every symlink resolved, or nil when the path doesn't exist.
public func realPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(cString: resolved)
}

extension Processes {
  /// The processes other than this one whose working folder, program, or an
  /// open file is `folder` or inside it. An open directory is not an open
  /// file. open(2) refuses to open a directory for writing, so a process that
  /// only holds directories open, as a file watcher does, can't write through
  /// them. The working folder of a background ssh multiplexer is not a use,
  /// because ssh never reads or writes it after it starts. macOS lets a
  /// process read only its own user's processes, so the processes of root and
  /// of other users are left out. An empty list comes back when the folder
  /// doesn't exist, because its path can't be resolved.
  public static func using(_ folder: String) -> [FolderUser] {
    guard let root = realPath(folder) else { return [] }
    let me = getpid()
    return allPids().filter { $0 != me }.compactMap { pid in
      firstUse(of: pid) { $0 == root || $0.hasPrefix(root + "/") }.map {
        FolderUser(pid: Int(pid), use: $0.use, path: $0.path)
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
  private static func firstUse(of pid: pid_t, where matches: (String) -> Bool) -> (use: FolderUse, path: String)? {
    var programBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let program =
      proc_pidpath(pid, &programBuffer, UInt32(programBuffer.count)) > 0 ? String(cString: programBuffer) : nil
    var vnodes = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodes, size) == size {
      let cwd = pathString(&vnodes.pvi_cdir.vip_path)
      if matches(cwd), !isSSHMultiplexer(pid, program: program) { return (.workingFolder, cwd) }
    }
    if let program, matches(program) { return (.program, program) }
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
      guard info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT != S_IFDIR else { continue }
      let path = pathString(&info.pvip.vip_path)
      if matches(path) { return (.openFile, path) }
    }
    return nil
  }

  /// Whether the process is the background master that ssh starts for
  /// ControlPersist. That master renames itself `ssh: <socket> [mux]`.
  private static func isSSHMultiplexer(_ pid: pid_t, program: String?) -> Bool {
    guard let program, (program as NSString).lastPathComponent == "ssh",
      let name = firstArgument(of: pid)
    else { return false }
    return name.hasPrefix("ssh: ") && name.hasSuffix(" [mux]")
  }

  /// The process's argv[0] as it reads now, which a process can overwrite to rename itself.
  private static func firstArgument(of pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    // The buffer holds argc, the program path, NUL padding, and then argv.
    var rest = buffer.prefix(size).dropFirst(MemoryLayout<Int32>.size)
    rest = rest.drop { $0 != 0 }.drop { $0 == 0 }
    let first = rest.prefix { $0 != 0 }
    return first.isEmpty ? nil : String(decoding: first, as: UTF8.self)
  }

  private static func pathString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
  }
}
