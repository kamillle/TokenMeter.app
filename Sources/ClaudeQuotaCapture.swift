import Foundation
import CoreFoundation
import Darwin

/// Stores only quota fields, never the session payload or credentials.
/// Version 2 adds per-window timestamps and a separate notification heartbeat.
enum ClaudeQuotaCapture {
    static let windowKeys = ["five_hour", "seven_day", "spend_limit"]

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func window(_ value: Any?) -> [String: Any]? {
        guard let raw = value as? [String: Any], let used = number(raw["used_percentage"]), used >= 0 else { return nil }
        var result: [String: Any] = ["used_percentage": used]
        if let reset = number(raw["resets_at"]), reset > 0 { result["resets_at"] = reset }
        return result
    }

    static func merging(_ payload: [String: Any], previous stored: [String: Any], now: Double, accountID: String? = nil) -> [String: Any] {
        // Do not retain another known account's quota across a login change.
        let previous = (stored["account_id"] as? String).map { $0 != accountID } == true ? [:] : stored
        let incoming = payload["rate_limits"] as? [String: Any] ?? [:]
        let old = previous["rate_limits"] as? [String: Any] ?? [:]
        let oldTimes = previous["window_observed"] as? [String: Any] ?? [:]
        let oldObserved = number(previous["observed"]) ?? 0
        var limits: [String: Any] = [:]
        var times: [String: Any] = [:]
        var received: [String] = []
        for key in windowKeys {
            let prior = window(old[key])
            if let next = window(incoming[key]) {
                limits[key] = next
                received.append(key)
                // A refresh timer can replay the same cached value indefinitely.
                // Do not turn such a replay into evidence of a new server fetch.
                if let prior, NSDictionary(dictionary: next).isEqual(to: prior) {
                    times[key] = number(oldTimes[key]) ?? oldObserved
                } else { times[key] = now }
            } else if let prior {
                limits[key] = prior
                times[key] = number(oldTimes[key]) ?? oldObserved
            }
        }
        return ["version": 2, "account_id": accountID as Any? ?? NSNull(), "observed": times.values.compactMap { number($0) }.min() ?? 0,
                "rate_limits": limits, "window_observed": times,
                "last_notification": now, "notification_windows": received]
    }

    static func save(_ payload: [String: Any], directory: URL, now: Double = Date().timeIntervalSince1970, accountID: String? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Multiple terminals share the same file. Lock the complete read/merge/write.
        let lock = open(directory.appendingPathComponent("claude-status.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError() }
        }
        defer { flock(lock, LOCK_UN) }
        let destination = directory.appendingPathComponent("claude-status.json")
        let previous = (try? Data(contentsOf: destination)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        } ?? [:]
        let capture = merging(payload, previous: previous, now: now, accountID: accountID)
        let data = try JSONSerialization.data(withJSONObject: capture, options: [.withoutEscapingSlashes])
        let temporary = directory.appendingPathComponent("claude-status.\(getpid()).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
