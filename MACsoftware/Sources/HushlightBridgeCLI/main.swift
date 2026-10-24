import BridgeCore
import Foundation

@main
struct HushlightBridgeCLI {
    static func main() async {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            hushlight-bridge [--simulate | --allow-volume-control] [--paused]
            Reads one bridge-v1 command.request JSON envelope per stdin line; writes one JSON response per line.
            Only local debug_console source is accepted. No network listener or device/cloud authentication.
            Default: real macOS system.volume.get only. --allow-volume-control also enables real system.volume.set/adjust.
            --simulate (debug builds only) uses in-memory volume (initial 50) for get/set/adjust and labels every response simulation.
            --paused rejects actions. Each line is limited to 65536 bytes.
            Replay and request-result caches last only for this process; new invocations start fresh.
            """)
            return
        }
        let supported: Set<String> = ["--simulate", "--allow-volume-control", "--paused"]
        guard arguments.allSatisfy(supported.contains),
              !(arguments.contains("--simulate") && arguments.contains("--allow-volume-control")) else {
            FileHandle.standardError.write(Data("Invalid options; use --help.\n".utf8))
            exit(2)
        }
        let runner: BridgeLocalCLIEngine
        do {
            runner = try await BridgeLocalCLIEngine(
                simulate: arguments.contains("--simulate"),
                allowVolumeControl: arguments.contains("--allow-volume-control"),
                paused: arguments.contains("--paused")
            )
        } catch {
            FileHandle.standardError.write(Data("Failed to initialize bridge.\n".utf8))
            exit(2)
        }
        var line = Data()
        var oversized = false
        while let chunk = try? FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            for byte in chunk {
                if byte == 10 {
                    let response = oversized
                        ? await runner.oversizedLineResponse()
                        : await runner.processLine(line)
                    FileHandle.standardOutput.write(response + Data([10]))
                    line.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if line.count < BridgeLocalCLIEngine.maximumLineBytes {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: true)
                        oversized = true
                    }
                }
            }
        }
        if oversized || !line.isEmpty {
            let response = oversized
                ? await runner.oversizedLineResponse()
                : await runner.processLine(line)
            FileHandle.standardOutput.write(response + Data([10]))
        }
    }
}
