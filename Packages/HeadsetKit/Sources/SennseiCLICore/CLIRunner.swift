import Foundation
import RemoteProtocol
import SennseiControl

public enum CLIRunner {

    public static func run(
        _ args: [String], socketURL: URL = ControlPaths.defaultSocketURL(), timeout: TimeInterval = 15
    ) -> CLIOutput.Result {
        switch CLICommand.parse(args) {
        case .failure(let e):
            return ("", "error: \(CLIOutput.sanitize(e.message))\n\n\(CLICommand.usage)\n", e.exitCode)
        case .success(.help):
            return (CLICommand.usage + "\n", "", 0)
        case .success(.version):
            return ("sennsei \(CLIVersion.current)\n", "", 0)
        case .success(.doctor):
            let r = CLIDoctor.run(socketURL: socketURL)
            return (r.report, "", r.exitCode)
        case .success(.send(let request, let style)):
            do {
                let response = try ControlClient(socketURL: socketURL, timeout: timeout).send(request)
                return CLIOutput.render(response, for: request, style: style)
            } catch let e as ControlClientError {
                return CLIOutput.render(error: e)
            } catch {
                return ("", "error: \(CLIOutput.sanitize("\(error)"))\n", 1)
            }
        }
    }
}
