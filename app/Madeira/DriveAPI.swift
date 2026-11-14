// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

actor DriveAPI {
    static let shared = DriveAPI()
    private var generation = 0
    private var refresh: Task<DriveCredential, Error>?
    private let http: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { http = session }
    static let fields = "id,name,mimeType,size,md5Checksum,version,modifiedTime,resourceKey,trashed,capabilities(canDownload,canListChildren)"
    struct Token: Decodable { var access_token: String; var expires_in: Double; var refresh_token: String?; var scope: String? }

    private func token(_ values: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw DriveError.signIn }
        guard status == 200 else { throw DriveError.http(status, "token refresh") }
        return try JSONDecoder().decode(Token.self, from: data)
    }
    func exchange(code: String, verifier: String) async throws -> DriveAccount {
        let revision = generation
        let token = try await token(["client_id": DriveOAuth.clientID, "redirect_uri": DriveOAuth.redirect,
                                    "code": code, "code_verifier": verifier, "grant_type": "authorization_code"])
        guard token.scope?.split(separator: " ").contains(Substring(DriveOAuth.scope)) == true,
              let refreshToken = token.refresh_token else { throw DriveError.message("Allow Google Drive read access to connect this account.") }
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DriveError.signIn }
        struct User: Decodable { var sub: String; var email: String? }
        let user = try JSONDecoder().decode(User.self, from: data)
        guard generation == revision else { throw CancellationError() }
        // An older refresh must never overwrite a newly connected account.
        generation += 1; refresh?.cancel(); refresh = nil
        let account = DriveAccount(id: user.sub, email: user.email ?? "Google account")
        try DriveKeychain.save(DriveCredential(account: account, accessToken: token.access_token, refreshToken: refreshToken,
                                              expires: Date().addingTimeInterval(token.expires_in), clientID: DriveOAuth.clientID))
        return account
    }
    func disconnect() throws {
        generation += 1; refresh?.cancel(); refresh = nil
        try DriveKeychain.delete()
    }
    func access(account: String, force: Bool = false) async throws -> String {
        guard let credential = try DriveKeychain.load(), credential.account.id == account,
              credential.clientID == DriveOAuth.clientID else { throw DriveError.signIn }
        if !force && credential.expires.timeIntervalSinceNow > 120 { return credential.accessToken }
        let revision = generation
        if let refresh {
            let next = try await refresh.value
            guard revision == generation else { throw CancellationError() }
            return next.accessToken
        }
        let work = Task { () throws -> DriveCredential in
            let fresh = try await self.token(["client_id": DriveOAuth.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"])
            var next = credential
            next.accessToken = fresh.access_token; next.expires = Date().addingTimeInterval(fresh.expires_in)
            next.refreshToken = fresh.refresh_token ?? credential.refreshToken
            return next
        }
        refresh = work
        defer { if revision == generation { refresh = nil } }
        let next = try await work.value
        guard revision == generation else { throw CancellationError() }
        try DriveKeychain.save(next)
        return next.accessToken
    }
    static func error(status: Int, data: Data) -> DriveError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let reasons = error?["errors"] as? [[String: Any]]
        return .http(status, reasons?.first?["reason"] as? String ?? "")
    }
    private func json<T: Decodable>(_ url: URL, account: String, keys: String? = nil) async throws -> T {
        for attempt in 0..<2 {
            let access = try await access(account: account, force: attempt > 0)
            var request = URLRequest(url: url)
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            if let keys { request.setValue(keys, forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") }
            let (data, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { continue }
            guard status == 200 else { throw Self.error(status: status, data: data) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw DriveError.signIn
    }
    static func fileURL(_ id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 256, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
            throw DriveError.message("Invalid Google Drive file ID.")
        }
        return URL(string: "https://www.googleapis.com/drive/v3/files/" + id)!
    }
    func metadata(_ file: DriveRemoteFile, account: String) async throws -> DriveRemoteFile {
        var url = URLComponents(url: try Self.fileURL(file.id), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        return try await json(url.url!, account: account, keys: file.resourceKey.map { file.id + "/" + $0 })
    }
    func list(_ folder: DriveRemoteFile, account: String) async throws -> [DriveRemoteFile] {
        _ = try Self.fileURL(folder.id)
        struct Page: Decodable { var files: [DriveRemoteFile]; var nextPageToken: String?; var incompleteSearch: Bool? }
        var result: [DriveRemoteFile] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.queryItems = [URLQueryItem(name: "q", value: "'\(folder.id)' in parents and trashed = false"),
                URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fields))"),
                URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "includeItemsFromAllDrives", value: "true")]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
            let page: Page = try await json(url.url!, account: account, keys: folder.resourceKey.map { folder.id + "/" + $0 })
            guard page.incompleteSearch != true, result.count + page.files.count <= 100_000 else {
                throw DriveError.message("This folder could not be listed completely. Choose a smaller folder.")
            }
            result += page.files; cursor = page.nextPageToken
            if let cursor, !seen.insert(cursor).inserted { throw DriveError.message("Drive repeated a folder page. Refresh and try again.") }
        } while cursor != nil
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func plan(_ source: DriveRemoteFile, account: String) async throws -> DriveJob {
        let source = try await metadata(source, account: account)
        guard source.isFolder || source.isZIP else { throw DriveError.message("Select a ZIP file or a game folder.") }
        var files: [DriveFilePlan] = [], directories: [String] = []
        func add(_ file: DriveRemoteFile, path: String) throws {
            guard !file.mimeType.hasPrefix("application/vnd.google-apps."), file.capabilities?.canDownload != false,
                  let bytes = file.byteCount, file.trashed != true else {
                throw DriveError.message("This item cannot be downloaded: \(file.name). Shortcuts and Google documents are not supported.")
            }
            files.append(DriveFilePlan(remote: file, path: try DrivePaths.relative(path), bytes: bytes))
        }
        if source.isFolder {
            var queue = [(source, "")]; var cursor = 0; var visited = Set<String>()
            while cursor < queue.count {
                try Task.checkCancellation()
                let (folder, path) = queue[cursor]; cursor += 1
                guard visited.insert(folder.id).inserted, cursor <= 10_000 else { throw DriveError.message("The folder tree is too large or contains a cycle.") }
                for child in try await list(folder, account: account) {
                    let relative = path.isEmpty ? child.name : path + "/" + child.name
                    _ = try DrivePaths.relative(relative)
                    if child.isFolder { directories.append(relative); queue.append((child, relative)) }
                    else { try add(child, path: relative) }
                    guard files.count + directories.count <= 100_000 else { throw DriveError.message("Too many files. Store this game as a ZIP instead.") }
                }
            }
        } else { try add(source, path: "archive.zip") }
        guard !files.isEmpty else { throw DriveError.message("This folder has no downloadable game files.") }
        try DrivePaths.validate(files: files, directories: directories)
        return DriveJob(accountID: account, source: source, title: source.isZIP ? String(source.name.dropLast(4)) : source.name,
                        files: files, directories: directories)
    }
    func request(_ file: DriveRemoteFile, block: DriveBlock, account: String) async throws -> URLRequest {
        var url = URLComponents(url: try Self.fileURL(file.id), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + (try await access(account: account)), forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(block.offset)-\(block.offset + block.length - 1)", forHTTPHeaderField: "Range")
        if let key = file.resourceKey { request.setValue(file.id + "/" + key, forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") }
        return request
    }
}
