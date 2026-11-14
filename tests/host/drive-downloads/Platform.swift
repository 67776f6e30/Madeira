// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Host-only platform signatures for type-checking the actual queue coordinator.
// These do NOT test UIKit lifecycle or OS background transfer behavior.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
struct UIBackgroundTaskIdentifier: Equatable { static let invalid = Self() }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, background }
    var applicationState = State.active
    static let didBecomeActiveNotification = Notification.Name("active")
    static let didEnterBackgroundNotification = Notification.Name("background")
    func beginBackgroundTask(withName name: String, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {}
}
@MainActor protocol UIApplicationDelegate {}
final class UNMutableNotificationContent { var title = ""; var body = "" }
struct UNNotificationRequest { init(identifier: String, content: UNMutableNotificationContent, trigger: Int?) {} }
struct UNAuthorizationOptions: OptionSet { var rawValue: Int; static let alert = Self(rawValue: 1); static let sound = Self(rawValue: 2) }
final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { Self() }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: (Bool, Error?) -> Void) { completionHandler(false, nil) }
    func add(_ request: UNNotificationRequest) {}
}
struct ASWebAuthenticationSessionError: Error {
    enum Code { case canceledLogin }; var code: Code
}
@MainActor final class DriveSignIn {
    static let shared = DriveSignIn()
    func run() async throws -> DriveAccount { throw DriveError.signIn }
}
@MainActor final class LibraryModel {
    struct Entry { var driveJobID: UUID? }
    static let shared = LibraryModel()
    static var drive: URL { URL(fileURLWithPath: "/tmp/drive-typecheck") }
    var entries: [Entry] = []
    func upsertDrive(id: UUID, title: String, path: String) {}
}
