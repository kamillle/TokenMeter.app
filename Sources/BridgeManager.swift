import Foundation
import Darwin

enum BridgeError: LocalizedError {
    case invalidSettings
    case missingHelper

    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "設定を更新できませんでした。設定ファイルの形式とアクセス権を確認してください"
        case .missingHelper: return "Claude連携用プログラムが見つかりません"
        }
    }
}

final class BridgeManager: @unchecked Sendable {
    let stateDirectory: URL
    let claudeDirectory: URL
    let helperSource: URL?
    private let fileManager = FileManager.default
    private let migrationLock = NSLock()
    private var checkedInstalledHelper = false

    init(
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageBar"),
        claudeDirectory: URL? = nil,
        helperSource: URL? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.stateDirectory = stateDirectory
        self.claudeDirectory = claudeDirectory ?? URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
        self.helperSource = helperSource ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/TokenMeterClaudeBridge")
    }

    func setup(remove: Bool = false) throws -> String {
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        var settings: [String: Any]
        if fileManager.fileExists(atPath: settingsURL.path) {
            guard let loaded = readObject(settingsURL) else { throw BridgeError.invalidSettings }
            settings = loaded
        } else { settings = [:] }

        try privateDirectory(stateDirectory)
        var config = readObject(stateDirectory.appendingPathComponent("bridge-config.json")) ?? [:]
        let current = settings["statusLine"] as? [String: Any] ?? [:]
        let currentCommand = current["command"] as? String ?? ""
        let ours = isTokenMeterCommand(currentCommand)

        if remove {
            if ours {
                if let original = config["original"], !(original is NSNull) {
                    settings["statusLine"] = original
                } else { settings.removeValue(forKey: "statusLine") }
                try atomicWrite(settings, to: settingsURL)
            }
            config["installed"] = false
            try atomicWrite(config, to: stateDirectory.appendingPathComponent("bridge-config.json"))
            return "Claude連携を解除しました"
        }

        guard let helperSource, fileManager.fileExists(atPath: helperSource.path) else { throw BridgeError.missingHelper }
        if !ours {
            config = ["original": settings["statusLine"] ?? NSNull(), "installed": true]
            let backup = stateDirectory.appendingPathComponent("statusline-backup-\(DispatchTime.now().uptimeNanoseconds).json")
            try atomicWrite(config, to: backup)
        }
        let installedHelper = stateDirectory.appendingPathComponent("TokenMeterClaudeBridge")
        let temporaryHelper = stateDirectory.appendingPathComponent("TokenMeterClaudeBridge.\(getpid()).tmp")
        if fileManager.fileExists(atPath: temporaryHelper.path) { try fileManager.removeItem(at: temporaryHelper) }
        try fileManager.copyItem(at: helperSource, to: temporaryHelper)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryHelper.path)
        guard Darwin.rename(temporaryHelper.path, installedHelper.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var statusLine = current
        statusLine["type"] = "command"
        statusLine["command"] = shellQuote(installedHelper.path)
        statusLine["refreshInterval"] = 60
        settings["statusLine"] = statusLine
        config["installed"] = true
        try atomicWrite(config, to: stateDirectory.appendingPathComponent("bridge-config.json"))
        try atomicWrite(settings, to: settingsURL)
        return "Claude連携を有効にしました。既存のステータスライン表示は維持されます"
    }

    func migrateLegacyBridgeIfNeeded() {
        migrationLock.lock()
        guard !checkedInstalledHelper else { migrationLock.unlock(); return }
        checkedInstalledHelper = true
        migrationLock.unlock()
        let config = readObject(stateDirectory.appendingPathComponent("bridge-config.json")) ?? [:]
        guard (config["installed"] as? NSNumber)?.boolValue == true else { return }
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        guard let settings = readObject(settingsURL),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              isTokenMeterCommand(command) else { return }
        _ = try? setup()
    }

    private func isTokenMeterCommand(_ command: String) -> Bool {
        // Recognize installed helpers from both names without replacing the saved original command.
        command.contains("TokenMeterClaudeBridge") || command.contains("UsageBarClaudeBridge") ||
            (command.contains("UsageBar") && command.contains("claude_bridge.py"))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func privateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func atomicWrite(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else { throw BridgeError.invalidSettings }
        try privateDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".\(getpid()).tmp")
        try data.write(to: temporary)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
