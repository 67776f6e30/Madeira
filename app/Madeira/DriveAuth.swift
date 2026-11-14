// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum DriveOAuth {
    static var clientID: String { Bundle.main.object(forInfoDictionaryKey: "MadeiraGoogleClientID") as? String ?? "" }
    static var scheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    static var redirect: String { scheme + ":/oauthredirect" }
    static let scope = "https://www.googleapis.com/auth/drive.readonly"
    static var configured: Bool {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.contains("YOUR_") && schemes.contains(scheme)
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DriveError.message("Could not start secure sign-in.")
        }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct DriveCredential: Codable, Sendable {
    var account: DriveAccount
    var accessToken: String
    var refreshToken: String
    var expires: Date
    var clientID: String
}

enum DriveKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "madeira.google-drive",
         kSecAttrAccount as String: "oauth", kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> DriveCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw DriveError.message("Unlock your device to access the Google account.")
        }
        return try JSONDecoder().decode(DriveCredential.self, from: data)
    }
    static func save(_ credential: DriveCredential) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw DriveError.message("Could not save the Google account in Keychain.")
            }
        } else if status != errSecSuccess { throw DriveError.message("Could not update the Google account in Keychain.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveError.message("Could not remove the Google account.") }
    }
}

/// System browser OAuth with PKCE. No webview, client secret, or token logging.
@MainActor final class DriveSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DriveSignIn()
    private var session: ASWebAuthenticationSession?
    private var window: UIWindow?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window! }

    func run() async throws -> DriveAccount {
        guard DriveOAuth.configured else {
            throw DriveError.message("Google Drive is not configured in this build. Set MadeiraGoogleClientID and its reversed URL scheme in Info.plist; see docs/GOOGLE_DRIVE.md.")
        }
        guard session == nil else { throw DriveError.message("Google sign-in is already open.") }
        window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first { $0.isKeyWindow }
        guard window != nil else { throw DriveError.message("Open Madeira to sign in.") }
        let verifier = try DriveOAuth.random(), state = try DriveOAuth.random()
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": DriveOAuth.clientID, "redirect_uri": DriveOAuth.redirect,
            "response_type": "code", "scope": "openid email " + DriveOAuth.scope, "state": state,
            "code_challenge": DriveOAuth.base64(Data(SHA256.hash(data: Data(verifier.utf8)))),
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        defer { session = nil; window = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let browser = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: DriveOAuth.scheme) { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: DriveError.signIn) }
            }
            browser.presentationContextProvider = self
            session = browser
            if !browser.start() { continuation.resume(throwing: DriveError.message("Could not open Google sign-in.")) }
        }
        guard let response = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callback.scheme == DriveOAuth.scheme, callback.path == "/oauthredirect",
              response.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = response.queryItems?.first(where: { $0.name == "code" })?.value else { throw DriveError.signIn }
        return try await DriveAPI.shared.exchange(code: code, verifier: verifier)
    }
}
