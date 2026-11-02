import Foundation
import SwitchboardCore
import SwitchboardService

// sbd: the Switchboard service. It keeps session state in $SB_HOME, runs the
// terminals, takes hook events from `sb hook`, and stops idle sessions.
// Usage: sbd [--home <folder>]

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("sbd: \(message)\n".utf8))
  exit(1)
}

var homePath: String?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
  switch arg {
  case "--home": homePath = args.popFirst()
  case "--version":
    print("sbd \(Version.text)")
    exit(0)
  default: fail("unknown argument \(arg). Usage: sbd [--home <folder>]")
  }
}

let home = Home(path: homePath)
do { try home.create() } catch { fail("can't create \(home.path): \(error)") }
// The lock lives as long as this process. O_CLOEXEC keeps the terminals that
// sbd starts from inheriting it, which would hold the lock after sbd exits.
let lockFile = open(home.lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if lockFile < 0 { fail("can't open \(home.lock): \(String(cString: strerror(errno)))") }
if flock(lockFile, LOCK_EX | LOCK_NB) != 0 {
  if errno == EWOULDBLOCK { fail("another sbd already serves \(home.socket)") }
  fail("can't lock \(home.lock): \(String(cString: strerror(errno)))")
}

let service: Service
let server: Server
do {
  service = try Service(home: home, sbPath: siblingExecutable("sb"))
  try service.load()
  server = try Server(service: service)
} catch {
  fail("\(error)")
}

// A client that disconnects mid-reply raises SIGPIPE, which would end sbd.
signal(SIGPIPE, SIG_IGN)
var signals: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
  signal(sig, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  source.setEventHandler {
    unlink(home.socket)
    exit(0)
  }
  source.resume()
  signals.append(source)
}

server.run()
service.startPollers()
let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sbd.tick"))
ticker.schedule(deadline: .now() + service.tickSeconds, repeating: service.tickSeconds)
ticker.setEventHandler { service.tick() }
ticker.resume()
logLine("sbd \(Version.text) serving \(home.socket)")
dispatchMain()
