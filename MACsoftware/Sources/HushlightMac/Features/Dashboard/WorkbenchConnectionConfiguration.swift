import Foundation

enum WorkbenchConnectionConfiguration {
    static func command(executable: String, credential: String) -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        return quote(executable) + " --credential-file " + quote(credential)
    }

    static func toml(clientID: String, executable: String, credential: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ value: String) -> String {
            String(data: try! encoder.encode(value), encoding: .utf8)!
        }
        let name = clientID.replacingOccurrences(of: "-", with: "_")
        return "[mcp_servers.agent_workbench_\(name)]\ncommand = \(quoted(executable))\nargs = [\"--credential-file\", \(quoted(credential))]\n"
    }
}
