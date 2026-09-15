import Foundation
import TactionKit
import TactionDaemon

// tactiond: headless form of the Taction daemon, for development and debugging.
// The menu bar app (Taction.app) runs the same Daemon in-process; do not run both at once.

let version = TactionVersion.current

let usage = """
usage: tactiond [--foreground] [--config PATH] [--no-seize] [--debug] [--record FILE]
       tactiond --status
       tactiond --write-default-config [--config PATH]
       tactiond --version

  --foreground   log to stderr as well as os_log, and show the permission prompts
  --config PATH  config file (default ~/Library/Application Support/Taction/config.json)
  --no-seize     override the config and open the panel without exclusive access
  --debug        override the config log level to debug
  --record FILE  append every raw report to FILE (taction-probe capture format) for replay
  --status       print the daemon's last written status and exit
"""

var foreground = false
var configURL = TactionConfig.defaultConfigURL
var noSeize = false
var debug = false
var showStatus = false
var writeDefault = false
var recordURL: URL?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--foreground", "-f": foreground = true
    case "--config": i += 1; guard i < args.count else { fputs(usage, stderr); exit(1) }; configURL = URL(fileURLWithPath: args[i])
    case "--no-seize": noSeize = true
    case "--debug": debug = true
    case "--record": i += 1; guard i < args.count else { fputs(usage, stderr); exit(1) }; recordURL = URL(fileURLWithPath: args[i])
    case "--status": showStatus = true
    case "--write-default-config": writeDefault = true
    case "--version": print("tactiond \(version)"); exit(0)
    case "-h", "--help": print(usage); exit(0)
    default: fputs("unknown argument \(args[i])\n\(usage)", stderr); exit(1)
    }
    i += 1
}

if showStatus {
    do {
        print(try Status.read().humanReadable)
        exit(0)
    } catch {
        print("no status available (\(error.localizedDescription)); is tactiond running?")
        exit(1)
    }
}

if writeDefault {
    do {
        try TactionConfig().write(to: configURL)
        print("wrote \(configURL.path)")
        exit(0)
    } catch {
        fputs("could not write \(configURL.path): \(error)\n", stderr)
        exit(1)
    }
}

var config: TactionConfig
do {
    config = try TactionConfig.loadOrCreate(at: configURL)
} catch {
    fputs("config error at \(configURL.path): \(error)\nfix the file or delete it to regenerate defaults\n", stderr)
    exit(1)
}
if noSeize { config.seize = false }
if debug { config.logLevel = .debug }

let daemon = Daemon(config: config, configURL: configURL, foreground: foreground, recordURL: recordURL)
daemon.start()
RunLoop.main.run()
