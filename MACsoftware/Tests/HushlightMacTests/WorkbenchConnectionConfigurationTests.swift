import XCTest
@testable import HushlightMac

final class WorkbenchConnectionConfigurationTests: XCTestCase {
    func testConfigurationHasActualLinesAndQuotesPaths() {
        let config = WorkbenchConnectionConfiguration.toml(clientID: "a-b", executable: "/A B/mcp", credential: "/C/\"中文\".credential")
        XCTAssertEqual(config, "[mcp_servers.agent_workbench_a_b]\ncommand = \"/A B/mcp\"\nargs = [\"--credential-file\", \"/C/\\\"中文\\\".credential\"]\n")
        XCTAssertFalse(config.contains("\\ncommand"))
    }

    func testCommandQuotesApostrophesWithoutExpansion() {
        XCTAssertEqual(WorkbenchConnectionConfiguration.command(executable: "/A B/mcp", credential: "/C/it's.credential"), "'/A B/mcp' --credential-file '/C/it'\"'\"'s.credential'")
    }
}
