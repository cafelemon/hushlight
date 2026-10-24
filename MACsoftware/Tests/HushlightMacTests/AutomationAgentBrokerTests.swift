import Foundation
import XCTest
import BridgeCore
import WorkbenchKit
@testable import HushlightMac

private actor WorkerHostBridge: BridgeService {
    func snapshot() async throws -> BridgeSnapshot { .init(status: .localReady, permissions: [], recentActions: []) }
    func workbenchState() async throws -> WorkbenchServiceState { .init(status: "localReady", supportedActions: [], isSimulation: true) }
    func setPaused(_ value: Bool) async throws {}
    func readSystemVolume() async throws -> VolumeReadback { throw BridgeServiceError.notConfigured }
}

final class AutomationAgentBrokerTests: XCTestCase {
    func testAssignedLeaseWrongIdentityLateAndRevokedCannotSubmit() async throws {
        let broker = AutomationAgentBroker()
        let rule = AutomationRule(id: "rule", title: "Analysis", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300), grantedActions: [.notify])
        let task = Task { try await broker.analyze(clientID: "assigned", rule: rule, item: .init(sourceID: "source", occurredAt: Date(), text: "private")) }
        let job = try await waitForJob(broker, client: "assigned")
        let wrong = await broker.claim(clientID: "other")
        XCTAssertNil(wrong)
        let decisions: [AutomationAgentDecision] = [.init(action: .notify, title: "Summary", body: "Important", confidence: 1)]
        do { try await broker.submit(clientID: "other", jobID: job.id, leaseID: job.leaseID, decisions: decisions); XCTFail("Wrong identity") }
        catch AutomationError.unauthorized {}
        await broker.revoke(clientID: "assigned")
        do { _ = try await task.value; XCTFail("Revoked result") } catch AutomationError.unauthorized {}
        do { try await broker.submit(clientID: "assigned", jobID: job.id, leaseID: job.leaseID, decisions: decisions); XCTFail("Expired lease") }
        catch AutomationError.unauthorized {}
    }

    func testHostAuthenticatesJobClaimsAndValidatesLeaseSubmission() async throws {
        let root = URL(fileURLWithPath: "/tmp/worker-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = AutomationAgentBroker(), host = try WorkbenchHost(bridge: WorkerHostBridge(), directory: root, agentBroker: broker)
        let client = try await host.createClient(name: "Worker")
        try await host.setGrants(clientID: client.id, grants: [.automationWorker])
        let rule = AutomationRule(id: "rule", title: "Analysis", trigger: .mailPoll(scopeID: "scope", intervalSeconds: 300), grantedActions: [.notify])
        let task = Task { try await broker.analyze(clientID: client.id, rule: rule, item: .init(sourceID: "source", occurredAt: Date(), text: "private")) }
        var job: AutomationAgentJob?
        for _ in 0..<100 {
            let response = await host.process(.init(requestID: UUID().uuidString, operation: "automation.claim", credential: client.credential))
            if case .object(let fields) = response.result, let value = fields["job"], value != .null {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                job = try decoder.decode(AutomationAgentJob.self, from: JSONEncoder().encode(value)); break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let claimed = try XCTUnwrap(job)
        let decisions = [AutomationAgentDecision(action: .notify, title: "Summary", body: "Important", confidence: 1)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let response = await host.process(.init(requestID: UUID().uuidString, operation: "automation.submit", parameters: .object(["job_id": .string(claimed.id), "lease_id": .string(claimed.leaseID), "decisions_json": .string(String(decoding: try encoder.encode(decisions), as: UTF8.self))]), credential: client.credential))
        XCTAssertEqual(response.status, "succeeded")
        let result = try await task.value
        XCTAssertEqual(result, decisions)
    }

    private func waitForJob(_ broker: AutomationAgentBroker, client: String) async throws -> AutomationAgentJob {
        for _ in 0..<100 {
            if let job = await broker.claim(clientID: client) { return job }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AutomationError.unavailableInput
    }
}
