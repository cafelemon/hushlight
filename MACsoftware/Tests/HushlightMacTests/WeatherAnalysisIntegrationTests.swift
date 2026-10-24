import BridgeCore
import Foundation
import XCTest
@testable import HushlightMac

final class WeatherAnalysisIntegrationTests: XCTestCase {
    func testLiveParisForecastProducesWeatherSuggestionsOnly() async throws {
        guard ProcessInfo.processInfo.environment["HUSHLIGHT_LIVE_WEATHER_AI_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in public MET forecast and Codex analysis smoke")
        }

        // This resource is a test-only grant descriptor. No engine or effect driver is created.
        let testFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushlight-weather-analysis-\(UUID().uuidString)", isDirectory: true)
        let noteResource = testFolder.appendingPathComponent("daily-note.txt").path
        let city = try XCTUnwrap(WeatherCities.byID("paris"))
        XCTAssertFalse(METWeatherBackend().isSimulation)

        print("weather_analysis stage=forecast_start")
        let report: WeatherReport
        do {
            report = try await METWeatherBackend().fetch(cityID: city.id)
        } catch let error as StableErrorCode {
            XCTFail("weather_analysis stage=forecast code=\(error.rawValue)")
            return
        } catch {
            XCTFail("weather_analysis stage=forecast code=unexpected")
            return
        }
        let now = Date()
        guard report.city == city, !report.isCached, report.hourly.count == 12,
              (0...86_400).contains(now.timeIntervalSince(report.modelUpdatedAt)),
              (0...300).contains(now.timeIntervalSince(report.fetchedAt)),
              abs(now.timeIntervalSince(report.current.time)) <= 5_400 else {
            XCTFail("weather_analysis stage=forecast code=invalid_or_stale_report")
            return
        }
        print("weather_analysis stage=forecast pass")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reportJSON = String(decoding: try encoder.encode(report), as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(WeatherReport.self, from: Data(reportJSON.utf8))
        guard roundTripped.city == city, roundTripped.current == report.current,
              roundTripped.hourly == report.hourly,
              abs(roundTripped.modelUpdatedAt.timeIntervalSince(report.modelUpdatedAt)) < 1,
              abs(roundTripped.fetchedAt.timeIntervalSince(report.fetchedAt)) < 1 else {
            XCTFail("weather_analysis stage=input code=iso_json_roundtrip")
            return
        }

        let rule = AutomationRule(
            id: "test.public.paris.weather", title: "Paris weather analysis",
            trigger: .morningWeather(cityID: city.id, timeZoneID: city.timeZoneID),
            grantedActions: [.notify, .appendDailyNote],
            resourceIDs: [.appendDailyNote: noteResource], enabled: true)
        let item = AutomationInputItem(
            sourceID: "test.public.met.paris", occurredAt: report.fetchedAt,
            text: reportJSON, metadata: ["source": "weather.paris", "city": city.name])

        print("weather_analysis stage=analysis_start")
        let decisions: [AutomationAgentDecision]
        do {
            decisions = try await CodexAutomationAnalyzer().analyze(rule: rule, item: item)
        } catch let error as CodexAutomationError {
            XCTFail("weather_analysis stage=analysis code=\(error.failureCode)")
            return
        } catch {
            XCTFail("weather_analysis stage=analysis code=unexpected")
            return
        }

        guard Set(decisions.map(\.action)) == Set([.notify, .appendDailyNote]), decisions.count == 2 else {
            XCTFail("weather_analysis stage=analysis code=missing_or_extra_actions")
            return
        }
        for decision in decisions {
            guard rule.grantedActions.contains(decision.action),
                  !decision.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !decision.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  decision.confidence.isFinite && (0...1).contains(decision.confidence),
                  decision.eventAt == nil, decision.eventEndAt == nil,
                  decision.timeZoneID == nil || decision.timeZoneID == city.timeZoneID,
                  decision.classification != "ads" else {
                XCTFail("weather_analysis stage=analysis code=invalid_decision_shape")
                return
            }
        }
        if let notify = decisions.first(where: { $0.action == .notify }) {
            let advice = (notify.title + " " + notify.body).lowercased()
            guard ["umbrella", "rain", "parapluie", "伞", "雨"].contains(where: advice.contains) else {
                XCTFail("weather_analysis stage=advice code=umbrella_missing")
                return
            }
            guard ["clothing", "wear", "coat", "jacket", "veste", "衣", "穿", "外套"].contains(where: advice.contains) else {
                XCTFail("weather_analysis stage=advice code=clothing_missing")
                return
            }
        }
        print("weather_analysis stage=analysis pass")
    }
}
