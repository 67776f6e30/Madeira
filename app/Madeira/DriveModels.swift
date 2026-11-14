// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

enum DriveError: LocalizedError {
    case message(String)
    case signIn
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .signIn: return "Connect your Google account to continue."
        case .http(let code, let reason):
            return "Google Drive returned HTTP \(code)\(reason.isEmpty ? "" : " (\(reason))")."
        }
    }
    var retryable: Bool {
        if case .http(let code, let reason) = self {
            return code == 429 || (500...599).contains(code)
                || (code == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason))
        }
        return false
    }
}

struct DriveAccount: Codable, Equatable, Sendable {
    var id: String
    var email: String
}

struct DriveRemoteFile: Codable, Identifiable, Hashable, Sendable {
    struct Capabilities: Codable, Hashable, Sendable { var canDownload: Bool?; var canListChildren: Bool? }
    var id: String
    var name: String
    var mimeType: String
    var size: String?
    var md5Checksum: String?
    var version: String?
    var modifiedTime: String?
    var resourceKey: String?
    var capabilities: Capabilities?
    var trashed: Bool?
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var isZIP: Bool { !isFolder && name.lowercased().hasSuffix(".zip") }
    var byteCount: Int64? { size.flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil } }
    static let root = DriveRemoteFile(id: "root", name: "My Drive", mimeType: "application/vnd.google-apps.folder")
    func sameContent(as other: Self) -> Bool {
        id == other.id && size == other.size && version == other.version
            && modifiedTime == other.modifiedTime && md5Checksum == other.md5Checksum
    }
}

struct DriveSelection: Codable, Sendable {
    var accountID: String
    var folder: DriveRemoteFile
    var displayPath: String
}

struct DriveFilePlan: Codable, Sendable {
    var remote: DriveRemoteFile
    var path: String
    var bytes: Int64
}

struct DriveJob: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case downloading, paused, retryWaiting, needsSignIn, downloaded, installing, chooseProgram, ready, failed
        var title: String {
            switch self {
            case .downloading: return "Downloading"
            case .paused: return "Paused"
            case .retryWaiting: return "Waiting to retry"
            case .needsSignIn: return "Sign in to resume"
            case .downloaded: return "Downloaded — ready to install"
            case .installing: return "Installing"
            case .chooseProgram: return "Choose a program"
            case .ready: return "Installed"
            case .failed: return "Stopped"
            }
        }
    }
    var id = UUID()
    var accountID: String
    var source: DriveRemoteFile
    var title: String
    var files: [DriveFilePlan]
    var directories: [String]
    var state: State = .downloading
    var message: String?
    var retryAt: Date?
    var retries = 0
    var programs: [String] = []
    var selectedProgram: String?
    var installedFolder: String?
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// Durable transfer identity, containing no URL, token, or user-controlled path.
struct DriveBlock: Codable, Hashable, Sendable {
    static let size: Int64 = 128 * 1024 * 1024
    var job: UUID
    var file: Int
    var offset: Int64
    var length: Int64
    var key: String { "\(job.uuidString):\(file):\(offset):\(length)" }
    init(job: UUID, file: Int, offset: Int64, length: Int64) {
        self.job = job; self.file = file; self.offset = offset; self.length = length
    }
    init?(_ key: String?) {
        guard let parts = key?.split(separator: ":"), parts.count == 4,
              let job = UUID(uuidString: String(parts[0])), let file = Int(parts[1]), file >= 0,
              let offset = Int64(parts[2]), offset >= 0, let length = Int64(parts[3]),
              length > 0, length <= Self.size, offset <= Int64.max - length else { return nil }
        self.init(job: job, file: file, offset: offset, length: length)
    }
    func belongs(to job: DriveJob) -> Bool {
        guard self.job == job.id, job.files.indices.contains(file), offset % Self.size == 0 else { return false }
        let bytes = job.files[file].bytes
        return offset < bytes && length == min(Self.size, bytes - offset)
    }
    func accepts(status: Int, contentRange: String?, received: Int64, total: Int64) -> Bool {
        guard received == length else { return false }
        if status == 200 { return offset == 0 && length == total }
        return status == 206 && contentRange == "bytes \(offset)-\(offset + length - 1)/\(total)"
    }
}

enum DrivePaths {
    /// Drive allows duplicate names and names that Windows cannot represent.
    static func component(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240,
              !name.contains(where: { "/\\:*?\"<>|".contains($0) }),
              !name.unicodeScalars.contains(where: { $0.value < 32 }),
              !name.hasSuffix("."), !name.hasSuffix(" ") else {
            throw DriveError.message("A Drive filename cannot be used on this device: \(name)")
        }
        let base = name.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !reserved.contains(base) else { throw DriveError.message("A reserved Windows filename was found: \(name)") }
        return name
    }
    static func relative(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 64, path.utf8.count < 4096 else {
            throw DriveError.message("A game path is too long.")
        }
        return try parts.map { try component(String($0)) }.joined(separator: "/")
    }
    static func collisionKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    static func validate(files: [DriveFilePlan], directories: [String]) throws {
        var names = Set<String>(); var total: Int64 = 0
        for path in directories + files.map(\.path) {
            _ = try relative(path)
            guard names.insert(collisionKey(path)).inserted else { throw DriveError.message("Two Drive items have the same local path: \(path)") }
        }
        let fileNames = Set(files.map { collisionKey($0.path) })
        for path in directories + files.map(\.path) {
            var parts = path.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !fileNames.contains(collisionKey(parts.joined(separator: "/"))) else {
                    throw DriveError.message("A file conflicts with a game folder.")
                }
            }
        }
        for file in files {
            guard file.bytes >= 0, total <= Int64.max - file.bytes else { throw DriveError.message("Invalid game size.") }
            total += file.bytes
        }
        guard total <= 8 * 1024 * 1024 * 1024 * 1024 else {
            throw DriveError.message("This selection exceeds 8 TB. Choose a smaller game folder.")
        }
    }
}
