import Darwin
import SennseiCLICore

signal(SIGPIPE, SIG_IGN)

/// write(2) loop that gives up quietly on EPIPE or any other error.
func writeAll(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        offset += n
    }
}

let result = CLIRunner.run(Array(CommandLine.arguments.dropFirst()))
writeAll(STDOUT_FILENO, result.stdout)
writeAll(STDERR_FILENO, result.stderr)
exit(result.exitCode)
