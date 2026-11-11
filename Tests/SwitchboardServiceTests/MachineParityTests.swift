import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// One folder that holds every path shape of the plan's parity table.
private struct ParityFolder {
  let root: String

  static let digits = "0123456789"
  static let oddNames = ["a b", "line\nbreak", "-dash", "héllo ✓ 日本", "it's", "$HOME", "semi;colon", "star*"]

  /// Paths that are a regular file, a link to one, or nothing that can be read.
  var filePaths: [String] {
    ["missing", "empty", "digits", "binary", "link-to-file", "broken-link", "unreadable", "missing/below"]
      .map { root + "/" + $0 } + ParityFolder.oddNames.map { root + "/" + $0 }
  }

  var folderPaths: [String] {
    ["folder", "empty-folder", "link-to-folder", "folder/", "unreadable-folder"].map { root + "/" + $0 } + [root]
  }

  var allPaths: [String] { filePaths + folderPaths + [root + "/digits/below", root + "/link-to-folder/child"] }

  init(_ root: String) throws {
    self.root = root
    let fm = FileManager.default
    func file(_ name: String, _ data: Data) throws { try data.write(to: URL(fileURLWithPath: root + "/" + name)) }
    try file("empty", Data())
    try file("digits", Data(ParityFolder.digits.utf8))
    try file("binary", Data((0...255).map { UInt8($0) }))
    try file("unreadable", Data("secret".utf8))
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/unreadable")
    for name in ParityFolder.oddNames { try file(name, Data("named \(name)".utf8)) }
    try fm.createDirectory(atPath: root + "/folder", withIntermediateDirectories: false)
    try file("folder/child", Data("child".utf8))
    try file("folder/.hidden", Data("hidden".utf8))
    try file("folder/..twodots", Data("x".utf8))
    try fm.createDirectory(atPath: root + "/folder/.hidden-folder", withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: root + "/folder/broken", withDestinationPath: root + "/nowhere")
    try fm.createDirectory(atPath: root + "/empty-folder", withIntermediateDirectories: false)
    try fm.createDirectory(atPath: root + "/unreadable-folder", withIntermediateDirectories: false)
    try file("unreadable-folder/inside", Data("x".utf8))
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/unreadable-folder")
    try fm.createSymbolicLink(atPath: root + "/link-to-file", withDestinationPath: root + "/digits")
    try fm.createSymbolicLink(atPath: root + "/link-to-folder", withDestinationPath: root + "/folder")
    try fm.createSymbolicLink(atPath: root + "/broken-link", withDestinationPath: root + "/nowhere")
    let changed = Date(timeIntervalSince1970: 1_700_000_000.25)
    try fm.setAttributes([.modificationDate: changed], ofItemAtPath: root + "/digits")
  }
}

private func sameTime(_ a: Date?, _ b: Date?) -> Bool {
  switch (a, b) {
  case (nil, nil): return true
  case (let a?, let b?): return abs(a.timeIntervalSince(b)) < 0.000_001
  default: return false
  }
}

private func label(_ path: String, in folder: ParityFolder) -> String {
  String(reflecting: String(path.dropFirst(folder.root.count)))
}

/// Runs the body with `LocalMachine`, an `SSHMachine` over the shell program, and one folder for both.
private func withBothMachines(
  _ program: String, environment: [String: String]? = nil,
  _ body: (LocalMachine, SSHMachine, ParityFolder) throws -> Void
) throws {
  try withRemoteShellTempFolder { root in
    let folder = try ParityFolder(root)
    let t = try TestShell.start(program, environment: environment)
    defer { t.shell.close() }
    try body(LocalMachine(), SSHMachine(shell: { t.shell }), folder)
    #expect(t.events.closes.isEmpty, "the shell closed during the test: \(t.events.closes)")
  }
}

@Suite struct MachineParityTests {
  @Test(.timeLimit(.minutes(2)), arguments: remoteShellPrograms)
  func readReturnsTheSameBytes(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      let offsets: [UInt64] = [0, 4, 10, 255, 500]
      let counts: [Int?] = [nil, 0, 3, 100]

      for path in folder.filePaths {
        for offset in offsets {
          for count in counts {
            let expected = local.read(path, from: offset, count: count)

            let actual = ssh.read(path, from: offset, count: count)

            #expect(
              actual == expected,
              "\(label(path, in: folder)) from \(offset) count \(String(describing: count))")
          }
        }
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func textReturnsTheSameString(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      for path in folder.filePaths {
        #expect(ssh.text(path) == local.text(path), "\(label(path, in: folder))")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func sizeReturnsTheSameCount(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      for path in folder.filePaths {
        #expect(ssh.size(path) == local.size(path), "\(label(path, in: folder))")
      }
      #expect(local.size(folder.root + "/digits") == 10)
      #expect(local.size(folder.root + "/link-to-file") == 10, "size follows a link")
    }
  }

  /// Decision 14: `SSHMachine` returns nil for anything but a regular file, where `LocalMachine` may not.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readAndSizeOfAFolderAreNilOnTheRemoteMachine(program: String) throws {
    try withBothMachines(program) { _, ssh, folder in
      for path in folder.folderPaths {
        #expect(ssh.read(path, from: 0, count: nil) == nil, "\(label(path, in: folder))")
        #expect(ssh.read(path, from: 0, count: 0) == nil, "\(label(path, in: folder))")
        #expect(ssh.size(path) == nil, "\(label(path, in: folder))")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func existsAndIsFolderAgree(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      for path in folder.allPaths {
        #expect(ssh.exists(path) == local.exists(path), "exists \(label(path, in: folder))")
        #expect(ssh.isFolder(path) == local.isFolder(path), "isFolder \(label(path, in: folder))")
      }
      #expect(local.exists(folder.root + "/digits"))
      #expect(!local.exists(folder.root + "/broken-link"))
      #expect(local.isFolder(folder.root + "/link-to-folder"))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func modifiedReturnsTheSameTime(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      for path in folder.allPaths {
        let expected = local.modified(path)

        let actual = ssh.modified(path)

        #expect(
          sameTime(actual, expected),
          "\(label(path, in: folder)): \(String(describing: actual)) is not \(String(describing: expected))")
      }
      #expect(sameTime(local.modified(folder.root + "/digits"), Date(timeIntervalSince1970: 1_700_000_000.25)))
      #expect(local.modified(folder.root + "/broken-link") != nil, "modified reads the link itself")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func listReturnsTheSameNames(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      for path in folder.allPaths {
        let expected = local.list(path).sorted()

        let actual = ssh.list(path).sorted()

        #expect(actual == expected, "\(label(path, in: folder))")
      }
      #expect(
        local.list(folder.root + "/folder").sorted() == ["..twodots", ".hidden", ".hidden-folder", "broken", "child"])
      #expect(local.list(folder.root).contains("line\nbreak"))
      #expect(local.list(folder.root + "/empty-folder") == [])
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func createFolderDoesTheSame(program: String) throws {
    try withBothMachines(program) { local, ssh, folder in
      let machines: [(String, any Machine)] = [("local", local), ("ssh", ssh)]
      var threw: [String: [Bool]] = [:]
      var made: [String: [Bool]] = [:]

      for (name, machine) in machines {
        let base = folder.root + "/made-by-" + name
        let paths = [
          folder.root + "/folder",
          base + "/a/b/c",
          base + "/a/b/c",
          base + "/with space/and\nnewline/-dash/héllo ✓",
          folder.root + "/link-to-folder/via-link-" + name,
          folder.root + "/digits/under-a-file",
          folder.root + "/digits",
          folder.root + "/broken-link/under",
          folder.root + "/unreadable-folder/under",
        ]
        for path in paths {
          var failed = false
          do { try machine.createFolder(path) } catch { failed = true }
          threw[name, default: []].append(failed)
          made[name, default: []].append(isDirectory(path))
        }
      }

      #expect(threw["ssh"] == threw["local"])
      #expect(made["ssh"] == made["local"])
      #expect(threw["local"]?.prefix(5) == [false, false, false, false, false])
      #expect(threw["local"]?[5] == true, "a folder under a file")
      #expect(local.list(folder.root + "/folder").contains("child"), "an existing folder keeps its contents")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func runReturnsTheSameResult(program: String) throws {
    let hostile = ["a b", "'", "\"", "`id`", "$HOME", ";", "line\nbreak", "-n", "", "héllo ✓"]
    let cases: [(String, [String], [String: String]?, Data?)] = [
      ("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], nil, nil),
      ("/usr/bin/true", [], nil, nil),
      ("/usr/bin/false", [], nil, nil),
      ("/bin/sh", ["-c", "exit 255"], nil, nil),
      ("/bin/sh", ["-c", #"for a do printf '%s|' "$a"; done"#, "sb"] + hostile, nil, nil),
      ("/bin/echo", hostile, nil, nil),
      ("/usr/bin/printf", ["no newline"], nil, nil),
      ("/bin/cat", [], nil, Data("line one\nline two\n".utf8)),
      ("/bin/cat", [], nil, Data()),
      ("/usr/bin/wc", ["-c"], nil, Data(count: 100_000)),
      (
        "/bin/sh", ["-c", #"printf '%s|%s|%s' "$A" "$B" "${SB_PARITY_LEAK-unset}""#], ["A": "a b'$HOME", "B": "x\ny"],
        nil
      ),
    ]
    try withBothMachines(program, environment: ["PATH": "/usr/bin:/bin", "SB_PARITY_LEAK": "from the shell"]) {
      local, ssh, _ in
      for (executable, args, env, input) in cases {
        let expected = try local.run(executable, args, env: env, input: input, timeout: nil)

        let actual = try ssh.run(executable, args, env: env, input: input, timeout: nil)

        let what = "\(executable) \(args.prefix(2))"
        #expect(actual.status == expected.status, "\(what)")
        #expect(actual.stdout == expected.stdout, "\(what)")
        #expect(actual.stderr == expected.stderr, "\(what)")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func signalEndsAChildTheSameWay(program: String) throws {
    try withBothMachines(program) { local, ssh, _ in
      var results: [[Int32]] = []
      for machine: any Machine in [local, ssh] {
        var statuses: [Int32] = []
        for signal in [SIGTERM, SIGKILL, SIGUSR1] {
          let child = Process()
          child.executableURL = URL(fileURLWithPath: "/bin/sleep")
          child.arguments = ["30"]
          try child.run()
          defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

          machine.signal(Int(child.processIdentifier), signal)
          child.waitUntilExit()

          statuses.append(child.terminationReason == .uncaughtSignal ? child.terminationStatus : -1)
        }
        results.append(statuses)
      }

      #expect(results[1] == results[0])
      #expect(results[0] == [SIGTERM, SIGKILL, SIGUSR1])
    }
  }

  /// `stat` on the shell's PATH is a script that records its arguments and runs Homebrew's `gstat`,
  /// so the handshake picks the GNU format and `size` and `modified` run it.
  @Test(.timeLimit(.minutes(1)), .enabled(if: findExecutable("gstat") != nil), arguments: remoteShellPrograms)
  func theGNUStatFormatGivesTheSameSizeAndTime(program: String) throws {
    let gstat = try #require(findExecutable("gstat"))
    try withRemoteShellTempFolder { bin in
      let log = bin + "/stat-arguments"
      let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\(shellQuote(log))\nexec \(shellQuote(gstat)) \"$@\"\n"
      try Data(script.utf8).write(to: URL(fileURLWithPath: bin + "/stat"))
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/stat")

      try withBothMachines(program, environment: ["PATH": "\(bin):/usr/bin:/bin"]) { local, ssh, folder in
        for path in folder.filePaths {
          #expect(ssh.size(path) == local.size(path), "size \(label(path, in: folder))")
        }
        for path in folder.allPaths {
          #expect(sameTime(ssh.modified(path), local.modified(path)), "modified \(label(path, in: folder))")
        }
      }

      let calls = try String(contentsOfFile: log, encoding: .utf8).components(separatedBy: "\n")
      #expect(calls.first == "-c %s %.9Y -- /", "the handshake ran the GNU format on /")
      #expect(calls.contains { $0.hasPrefix("-L -c %s %.9Y -- ") }, "size ran the GNU format")
      #expect(!calls.contains { $0.contains("%z %Fm") }, "the BSD format never ran")
    }
  }
}
