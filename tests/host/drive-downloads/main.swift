// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func check(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    guard try! condition() else { fatalError("FAIL: " + label) }; print("PASS: " + label)
}
func rejects(_ label: String, _ work: () throws -> Void) {
    do { try work(); fatalError("FAIL: " + label) } catch { print("PASS: " + label) }
}
func file(_ id: String = "f", name: String = "game.exe", bytes: Int64 = 3) -> DriveRemoteFile {
    DriveRemoteFile(id: id, name: name, mimeType: "application/octet-stream", size: String(bytes),
                    md5Checksum: "900150983cd24fb0d6963f7d28e17f72", version: "1")
}

final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var answer: (URLRequest) -> (Int, String) = { _ in (500, "{}") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.answer(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Checks {
    static func main() async throws {
        setbuf(stdout, nil)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["../escape", "/absolute", "a\\b", "CON.exe", "LPT1", "trail.", "trail ", "a:b"] {
            rejects("reject unsafe name " + name) { _ = try DrivePaths.component(name) }
        }
        check(try DrivePaths.relative("日本語/게임.exe") == "日本語/게임.exe", "Unicode paths")
        let f = file(), plan = DriveFilePlan(remote: file(), path: "game.exe", bytes: 3)
        rejects("case insensitive collision") { try DrivePaths.validate(files: [plan, DriveFilePlan(remote: f, path: "GAME.EXE", bytes: 3)], directories: []) }
        rejects("file conflicts with parent directory") { try DrivePaths.validate(files: [plan, DriveFilePlan(remote: f, path: "game.exe/data", bytes: 3)], directories: []) }
        rejects("negative size") { try DrivePaths.validate(files: [DriveFilePlan(remote: f, path: "a", bytes: -1)], directories: []) }
        rejects("overflow size") { try DrivePaths.validate(files: [DriveFilePlan(remote: f, path: "a", bytes: .max), plan], directories: []) }
        let composed = DriveFilePlan(remote: f, path: "é.exe", bytes: 3)
        rejects("Unicode normalization collision") { try DrivePaths.validate(files: [composed, DriveFilePlan(remote: f, path: "e\u{301}.exe", bytes: 3)], directories: []) }
        var job = DriveJob(accountID: "a", source: f, title: "Game", files: [plan], directories: [])
        let block = DriveBlock(job: job.id, file: 0, offset: 0, length: 3)
        check(DriveBlock(block.key) == block && block.belongs(to: job), "durable block identity")
        check(DriveBlock("bad:0:0:3") == nil, "reject invalid job ID")
        check(block.accepts(status: 206, contentRange: "bytes 0-2/3", received: 3, total: 3), "valid 206")
        check(!block.accepts(status: 206, contentRange: "bytes 1-3/4", received: 3, total: 3), "reject shifted content range")
        check(!block.accepts(status: 200, contentRange: nil, received: 3, total: 7), "never append full response to partial download")
        check(!block.accepts(status: 206, contentRange: "bytes 0-2/3", received: 2, total: 3), "reject truncated response")
        var changed = f; changed.version = "2"
        check(!f.sameContent(as: changed), "detect remote revision change")
        let large = DriveFilePlan(remote: f, path: "large.bin", bytes: (5 << 30) + 17)
        let largeJob = DriveJob(accountID: "a", source: f, title: "Large", files: [large], directories: [])
        let largeBlocks = DriveStorage.blocks(largeJob)
        check(largeBlocks.last!.offset > Int64(UInt32.max) && largeBlocks.last!.length == 17, "64-bit offsets beyond 4 GB")
        check(largeBlocks.allSatisfy { $0.belongs(to: largeJob) }, "every planned range is bounded")
        job.state = .paused
        let restored = try JSONDecoder().decode(DriveJob.self, from: JSONEncoder().encode(job))
        check(restored.state == .paused && restored.id == job.id, "paused queue survives serialization")

        try DriveStorage.directory(DriveStorage.root)
        let part = DriveStorage.block(block)
        try DriveStorage.directory(part.deletingLastPathComponent())
        try Data("abc".utf8).write(to: part)
        check(DriveStorage.has(block), "durable block recognized after relaunch")
        let output = DriveStorage.job(job.id).appendingPathComponent("assembled")
        try DriveStorage.assemble(plan, index: 0, job: job.id, to: output)
        check(try Data(contentsOf: output) == Data("abc".utf8), "disk assembly preserves bytes and verifies MD5")
        try Data("xyz".utf8).write(to: part)
        rejects("corrupt block fails checksum") { try DriveStorage.assemble(plan, index: 0, job: job.id, to: output) }
        check(!DriveStorage.has(block), "only invalid file blocks discarded for retry")
        check(try Data(contentsOf: output) == Data("abc".utf8), "failed assembly keeps prior output")
        try DriveStorage.directory(part.deletingLastPathComponent())
        try Data("ab".utf8).write(to: part)
        check(!DriveStorage.has(block), "truncated stored block is not resumed")
        let empty = DriveFilePlan(remote: DriveRemoteFile(id: "empty", name: "empty", mimeType: "application/octet-stream", size: "0", md5Checksum: "d41d8cd98f00b204e9800998ecf8427e"), path: "empty", bytes: 0)
        try DriveStorage.assemble(empty, index: 1, job: job.id, to: output)
        check(DriveStorage.size(output) == 0, "empty file needs no HTTP range")

        // ZIP and directory installations use the actual production storage/extractor.
        let zipURL = fixture.appendingPathComponent("game.zip")
        let zipData = try Data(contentsOf: zipURL)
        var zip = DriveRemoteFile(id: "zip", name: "Game.zip", mimeType: "application/zip", size: String(zipData.count))
        zip.md5Checksum = nil
        let zipJob = DriveJob(accountID: "a", source: zip, title: "ZIP", files: [DriveFilePlan(remote: zip, path: "archive.zip", bytes: Int64(zipData.count))], directories: [])
        let zipBlock = DriveStorage.blocks(zipJob)[0]
        try DriveStorage.directory(DriveStorage.block(zipBlock).deletingLastPathComponent())
        try zipData.write(to: DriveStorage.block(zipBlock))
        let drive = fixture.appendingPathComponent("drive_c")
        try DriveStorage.directory(drive)
        let (folder, programs) = try DriveStorage.install(zipJob, drive: drive)
        check(programs == ["Game/game.exe"], "ZIP extracts and discovers executable")
        check(try Data(contentsOf: drive.appendingPathComponent(folder + "/Game/data.bin")) == Data("payload".utf8), "ZIP preserves data paths")
        check(try DriveStorage.install(zipJob, drive: drive).0 == folder, "recover crash after installation rename")
        var folderJob = job; folderJob.id = UUID(); folderJob.source = DriveRemoteFile(id: "folder", name: "Game", mimeType: "application/vnd.google-apps.folder")
        folderJob.files = [DriveFilePlan(remote: f, path: "nested/game.exe", bytes: 3)]; folderJob.directories = ["nested", "empty"]
        let folderBlock = DriveStorage.blocks(folderJob)[0]
        try DriveStorage.directory(DriveStorage.block(folderBlock).deletingLastPathComponent()); try Data("abc".utf8).write(to: DriveStorage.block(folderBlock))
        let (folder2, programs2) = try DriveStorage.install(folderJob, drive: drive)
        check(programs2 == ["nested/game.exe"] && FileManager.default.fileExists(atPath: drive.appendingPathComponent(folder2 + "/empty").path), "folder install preserves hierarchy and empty directories")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let api = DriveAPI(session: URLSession(configuration: config))
        MockProtocol.answer = { request in
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            if request.url!.path.hasSuffix("/parent") { return (200, "{\"id\":\"parent\",\"name\":\"Game\",\"mimeType\":\"application/vnd.google-apps.folder\"}") }
            let q = url.queryItems?.first { $0.name == "q" }?.value ?? ""
            if q.contains("'child'") { return (200, "{\"files\":[{\"id\":\"exe\",\"name\":\"game.exe\",\"mimeType\":\"application/octet-stream\",\"size\":\"3\"}]}") }
            if url.queryItems?.contains(where: { $0.name == "pageToken" }) == true {
                return (200, "{\"files\":[{\"id\":\"data\",\"name\":\"data.bin\",\"mimeType\":\"application/octet-stream\",\"size\":\"4\"}]}")
            }
            return (200, "{\"nextPageToken\":\"page2\",\"files\":[{\"id\":\"child\",\"name\":\"nested\",\"mimeType\":\"application/vnd.google-apps.folder\"}]}")
        }
        let parent = DriveRemoteFile(id: "parent", name: "Game", mimeType: "application/vnd.google-apps.folder")
        let planned = try await api.plan(parent, account: "a")
        check(planned.files.map(\.path).sorted() == ["data.bin", "nested/game.exe"], "recursive folder planning includes every page")
        check(planned.totalBytes == 7, "recursive size calculation")
        let request = try await api.request(f, block: block, account: "a")
        check(request.value(forHTTPHeaderField: "Range") == "bytes=0-2", "authenticated range request")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer access", "token stays in Authorization header")
        do { _ = try await api.request(f, block: block, account: "other"); fatalError("FAIL: account isolation") }
        catch { print("PASS: account isolation") }
        MockProtocol.answer = { _ in (403, "{\"error\":{\"errors\":[{\"reason\":\"insufficientFilePermissions\"}]}}") }
        do { _ = try await api.list(parent, account: "a"); fatalError("FAIL: permission error") }
        catch let error as DriveError { check(!error.retryable, "permission failures are not blindly retried") }
        check(DriveAPI.error(status: 429, data: Data()).retryable, "rate limit is retryable")
        DriveKeychain.current?.expires = .distantPast
        MockProtocol.requests = []
        MockProtocol.answer = { _ in (200, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"refresh_token\":\"rotated\"}") }
        let access = try await api.access(account: "a")
        check(access == "fresh" && DriveKeychain.current?.refreshToken == "rotated", "expired access token refreshed and rotated token saved")
        check(MockProtocol.requests.count == 1 && MockProtocol.requests[0].url?.host == "oauth2.googleapis.com", "refresh uses Google token endpoint")
        DriveKeychain.current?.accessToken = "expired"
        MockProtocol.answer = { request in
            if request.url?.host == "oauth2.googleapis.com" { return (200, "{\"access_token\":\"fresh\",\"expires_in\":3600}") }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" { return (401, "{}") }
            return (200, "{\"id\":\"f\",\"name\":\"game.exe\",\"mimeType\":\"application/octet-stream\",\"size\":\"3\"}")
        }
        let refreshedFile = try await api.metadata(f, account: "a")
        check(refreshedFile.id == "f" && DriveKeychain.current?.accessToken == "fresh", "401 metadata response renews credentials and retries")
        MockProtocol.answer = { _ in (400, "{\"error\":\"invalid_grant\"}") }
        do { _ = try await api.access(account: "a", force: true); fatalError("FAIL: revoked refresh token") }
        catch DriveError.signIn { print("PASS: revoked refresh token requires sign-in") }
        MockProtocol.answer = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, "{\"access_token\":\"account-b-access\",\"expires_in\":3600,\"refresh_token\":\"account-b-refresh\",\"scope\":\"openid email https://www.googleapis.com/auth/drive.readonly\"}")
            }
            return (200, "{\"sub\":\"b\",\"email\":\"new@example.com\"}")
        }
        let connected = try await api.exchange(code: "authorization-code", verifier: "pkce-verifier")
        check(connected.id == "b" && DriveKeychain.current?.account.id == "b", "OAuth exchange replaces the connected account")
        do { _ = try await api.access(account: "a"); fatalError("FAIL: previous account after reconnection") }
        catch DriveError.signIn { print("PASS: previous account cannot use reconnected credentials") }
        try await api.disconnect()
        check(DriveKeychain.current == nil, "disconnect deletes credentials")
        print("All Google Drive core checks passed.")
    }
}
