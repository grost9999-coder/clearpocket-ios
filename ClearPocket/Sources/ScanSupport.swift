import Foundation
import UIKit

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// A finite extension for a user-started scan; iOS decides the available time.
@MainActor
final class BackgroundScanLease {
    let cancellation = ScanCancellation()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.cancellation.cancel()
                self?.end()
            }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// Checkpoints contain scan metadata only, live in the app sandbox, and are not backed up.
enum ScanCheckpoint {
    private static let lock = NSLock()
    private static func url(_ name: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanCheckpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return directory.appendingPathComponent(name + ".json")
    }
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    @discardableResult
    static func save<T: Encodable>(_ value: T, name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }
    static func clear(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(name))
    }
}
