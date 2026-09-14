import Foundation
import Darwin

@main
struct ClaudeBridgeMain {
    static func main() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        if let object { captureQuota(from: object) }
        if let status = runOriginalCommand(with: input) { exit(status) }
        let model = object?["model"] as? [String: Any]
        print(model?["display_name"] as? String ?? "Claude")
    }

    private static var stateDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["USAGEBAR_STATE_DIR"] { return URL(fileURLWithPath: configured) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageBar")
    }

    private static func captureQuota(from object: [String: Any]) {
        let capture: [String: Any] = [
            "observed": Date().timeIntervalSince1970,
            "rate_limits": object["rate_limits"] as? [String: Any] ?? [:]
        ]
        try? atomicWrite(capture, to: stateDirectory.appendingPathComponent("claude-status.json"))
    }

    private static func runOriginalCommand(with input: Data) -> Int32? {
        guard let config = readObject(stateDirectory.appendingPathComponent("bridge-config.json")),
              let original = config["original"] as? [String: Any],
              let command = original["command"] as? String,
              !command.contains("claude_bridge.py"), !command.contains("UsageBarClaudeBridge") else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = pipe
        do {
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
        } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        return process.terminationStatus
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func atomicWrite(_ object: [String: Any], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".\(getpid()).tmp")
        try data.write(to: temporary)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
