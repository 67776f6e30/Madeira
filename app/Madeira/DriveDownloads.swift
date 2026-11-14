// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Combine
import UIKit
import UserNotifications
import AuthenticationServices

/// URLSession owns transfers; this delegate survives SwiftUI views and moves temporary
/// files synchronously before returning. All queue mutations are delivered in order.
final class DriveTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Receipt { var url: URL; var status: Int; var range: String? }
    private var receipts: [Int: Receipt] = [:]
    private var failures: [Int: Error] = [:]
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DriveStorage.directory(DriveStorage.inbox)
            let url = DriveStorage.inbox.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: url)
            let response = downloadTask.response as? HTTPURLResponse
            receipts[downloadTask.taskIdentifier] = Receipt(url: url, status: response?.statusCode ?? 0,
                                                           range: response?.value(forHTTPHeaderField: "Content-Range"))
        } catch { failures[downloadTask.taskIdentifier] = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let receipt = receipts.removeValue(forKey: task.taskIdentifier)
        let failure = error ?? failures.removeValue(forKey: task.taskIdentifier)
        let id = task.taskIdentifier, key = task.taskDescription
        DispatchQueue.main.async { DriveDownloads.shared.completed(id: id, key: key, receipt: receipt, error: failure) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        DispatchQueue.main.async { DriveDownloads.shared.progress(id: id, bytes: totalBytesWritten) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { DriveDownloads.shared.finishBackgroundEvents() }
    }
}

@MainActor final class DriveDownloads: ObservableObject {
    static let shared = DriveDownloads()
    static let sessionID = "madeira.google-drive.downloads.v1"
    @Published private(set) var account: DriveAccount?
    @Published private(set) var selection: DriveSelection?
    @Published private(set) var jobs: [DriveJob] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var revision = 0
    @Published var wifiOnly = true {
        didSet {
            UserDefaults.standard.set(wifiOnly, forKey: "madeiraDriveWiFiOnly")
            if oldValue != wifiOnly {
                for (task, _) in running.values { task.cancel() }
            }
        }
    }
    private struct Saved: Codable { var selection: DriveSelection?; var jobs: [DriveJob] }
    private let delegate = DriveTransferDelegate()
    private var session: URLSession!
    private var running: [Int: (URLSessionDownloadTask, DriveBlock)] = [:]
    private var receivedBytes: [Int: Int64] = [:]
    private var completedKeys = Set<String>()
    private var plans: [UUID: [DriveBlock]] = [:]
    private var savedBytes: [UUID: Int64] = [:]
    private var savedCounts: [UUID: Int] = [:]
    private var cursors: [UUID: Int] = [:]
    private var lastProgress = Date.distantPast
    private var checkedFiles = Set<String>()
    private var renewAccounts = Set<String>()
    private var pumpTask: Task<Void, Never>?
    private var pumpRequested = false
    private var installer: (UUID, Task<(String, [String]), Error>)?
    private var retryTimer: Timer?
    private var restored = false
    private var started = false
    private var readOnly = false
    private var completion: (() -> Void)?
    private var eventsFinished = false
    private var installGrace: UIBackgroundTaskIdentifier = .invalid
    private var saveURL: URL { DriveStorage.root.appendingPathComponent("queue.json") }

    func start() {
        guard !started else { return }; started = true
        wifiOnly = UserDefaults.standard.object(forKey: "madeiraDriveWiFiOnly") as? Bool ?? true
        do {
            try DriveStorage.directory(DriveStorage.root)
            // A process may have died after moving a URLSession temporary file
            // but before accepting its range. Such inbox files are not checkpoints.
            if let leftovers = try? FileManager.default.contentsOfDirectory(at: DriveStorage.inbox, includingPropertiesForKeys: nil) {
                for url in leftovers where UUID(uuidString: url.lastPathComponent) != nil { try? FileManager.default.removeItem(at: url) }
            }
            account = try? DriveKeychain.load()?.account
            if FileManager.default.fileExists(atPath: saveURL.path) {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: saveURL))
                for job in saved.jobs { try DrivePaths.validate(files: job.files, directories: job.directories) }
                selection = saved.selection; jobs = saved.jobs
            }
            for index in jobs.indices {
                if jobs[index].state == .installing { jobs[index].state = .downloaded }
                if jobs[index].state == .downloading && jobs[index].accountID != account?.id { jobs[index].state = .needsSignIn }
                restoreBlocks(jobs[index])
            }
        } catch { self.error = error.localizedDescription; readOnly = true }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask, let block = DriveBlock(task.taskDescription),
                          let job = self.jobs.first(where: { $0.id == block.job }), block.belongs(to: job),
                          !self.readOnly, job.state == .downloading, job.accountID == self.account?.id,
                          !self.completedKeys.contains(block.key) else { task.cancel(); continue }
                    self.running[task.taskIdentifier] = (download, block)
                    if task.state == .suspended { task.resume() }
                }
                self.restored = true; self.kick()
            }
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.foreground() }
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.background() }
        }
    }
    private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            try JSONEncoder().encode(Saved(selection: selection, jobs: jobs))
                .write(to: saveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            revision += 1; return true
        } catch {
            self.error = "Could not save download progress: " + error.localizedDescription
            readOnly = true
            for (task, _) in running.values { task.cancel() }
            return false
        }
    }
    func signIn() async {
        guard !busy, !readOnly else { return }; busy = true; defer { busy = false }
        do {
            let account = try await DriveSignIn.shared.run()
            for index in jobs.indices where jobs[index].accountID != account.id && jobs[index].state == .downloading {
                pause(jobs[index].id)
            }
            self.account = account
            if selection?.accountID != account.id { selection = nil }
            _ = persist()
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin { }
        catch { self.error = error.localizedDescription }
    }
    func disconnect() async {
        guard !busy else { return }
        for id in jobs.filter({ $0.state == .downloading || $0.state == .retryWaiting }).map(\.id) { pause(id) }
        do { try await DriveAPI.shared.disconnect(); account = nil; selection = nil; _ = persist() }
        catch { self.error = error.localizedDescription }
    }
    func select(_ folder: DriveRemoteFile, path: String) {
        guard let account, folder.isFolder else { return }
        selection = DriveSelection(accountID: account.id, folder: folder, displayPath: path); _ = persist()
    }
    func enqueue(_ source: DriveRemoteFile) async {
        guard !busy, !readOnly, let account else { return }
        if jobs.contains(where: { $0.accountID == account.id && $0.source.id == source.id && $0.installedFolder == nil }) {
            error = "This item already has a download. Open Downloads to resume or install it."; return
        }
        busy = true; defer { busy = false }
        do {
            let job = try await DriveAPI.shared.plan(source, account: account.id)
            guard self.account?.id == account.id else { throw DriveError.signIn }
            try DriveStorage.requireSpace(job.totalBytes, at: DriveStorage.root)
            try DriveStorage.directory(DriveStorage.job(job.id))
            jobs.append(job)
            plans[job.id] = DriveStorage.blocks(job)
            guard persist() else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            kick()
        } catch { self.error = error.localizedDescription }
    }
    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .installing,
              jobs[index].state != .ready && jobs[index].state != .chooseProgram else { return }
        jobs[index].state = .paused; jobs[index].retryAt = nil; _ = persist()
        for (task, block) in running.values where block.job == id { task.cancel() }
    }
    func resume(_ id: UUID) {
        guard !readOnly, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .installing else { return }
        guard jobs[index].accountID == account?.id else { error = "Sign in with the Google account that owns this download."; return }
        guard ![.ready, .chooseProgram].contains(jobs[index].state) else { return }
        checkedFiles = checkedFiles.filter { !$0.hasPrefix(id.uuidString + ":") }
        restoreBlocks(jobs[index])
        jobs[index].state = .downloading; jobs[index].message = nil; jobs[index].retryAt = nil; jobs[index].retries = 0
        if persist() { kick() }
    }
    func cancel(_ id: UUID) {
        guard !readOnly, let job = jobs.first(where: { $0.id == id }), job.state != .installing,
              job.installedFolder == nil else { return }
        for (task, block) in running.values where block.job == id { task.cancel() }
        jobs.removeAll { $0.id == id }
        plans[id] = nil; savedBytes[id] = nil; savedCounts[id] = nil; cursors[id] = nil
        completedKeys = completedKeys.filter { !$0.hasPrefix(id.uuidString + ":") }
        if persist() { try? FileManager.default.removeItem(at: DriveStorage.job(id)) }
    }
    func progress(id: Int, bytes: Int64) {
        if let (_, block) = running[id] {
            receivedBytes[id] = min(block.length, max(0, bytes))
            if Date().timeIntervalSince(lastProgress) >= 0.25 { revision += 1; lastProgress = Date() }
        }
    }
    private func restoreBlocks(_ job: DriveJob) {
        let blocks = DriveStorage.blocks(job)
        plans[job.id] = blocks; cursors[job.id] = 0; savedBytes[job.id] = 0; savedCounts[job.id] = 0
        completedKeys = completedKeys.filter { !$0.hasPrefix(job.id.uuidString + ":") }
        for block in blocks where DriveStorage.has(block) {
            completedKeys.insert(block.key)
            savedBytes[job.id, default: 0] += block.length; savedCounts[job.id, default: 0] += 1
        }
    }
    func downloaded(_ job: DriveJob) -> Int64 {
        let saved = savedBytes[job.id, default: 0]
        return min(job.totalBytes, saved + running.reduce(Int64(0)) { sum, item in
            sum + (item.value.1.job == job.id && !completedKeys.contains(item.value.1.key) ? receivedBytes[item.key, default: 0] : 0)
        })
    }
    private func kick() {
        guard restored, !readOnly else { return }
        guard pumpTask == nil else { pumpRequested = true; return }
        pumpTask = Task {
            await self.pump(); self.pumpTask = nil
            if self.pumpRequested { self.pumpRequested = false; self.kick() }
            self.completeBackgroundEventsIfReady()
        }
    }
    private func pump() async {
        for accountID in Array(renewAccounts) {
            renewAccounts.remove(accountID)
            guard account?.id == accountID else { continue }
            do {
                _ = try await DriveAPI.shared.access(account: accountID, force: true)
                for index in jobs.indices where jobs[index].accountID == accountID && jobs[index].state == .retryWaiting {
                    jobs[index].retryAt = Date()
                }
            } catch {
                for id in jobs.filter({ $0.accountID == accountID && $0.state == .retryWaiting }).map(\.id) { fail(id, error: error) }
            }
        }
        for index in jobs.indices where jobs[index].state == .retryWaiting && (jobs[index].retryAt ?? .distantPast) <= Date() {
            jobs[index].state = .downloading
        }
        let ids = jobs.filter { $0.state == .downloading }.map(\.id)
        for id in ids {
            guard let job = jobs.first(where: { $0.id == id }), job.accountID == account?.id else { continue }
            do {
                let all = plans[id] ?? []
                var cursor = cursors[id, default: 0]
                while cursor < all.count && completedKeys.contains(all[cursor].key) { cursor += 1 }
                cursors[id] = cursor
                for block in all.dropFirst(cursor) where !completedKeys.contains(block.key) {
                    if running.count >= 8 { break }
                    if running.values.contains(where: { $0.1 == block }) { continue }
                    let fileKey = "\(id.uuidString):\(block.file)"
                    if !checkedFiles.contains(fileKey) {
                        let current = try await DriveAPI.shared.metadata(job.files[block.file].remote, account: job.accountID)
                        guard current.sameContent(as: job.files[block.file].remote), current.capabilities?.canDownload != false else {
                            throw DriveError.message("A source file changed or is no longer downloadable. Cancel this download and select the item again.")
                        }
                        checkedFiles.insert(fileKey)
                    }
                    var request = try await DriveAPI.shared.request(job.files[block.file].remote, block: block, account: job.accountID)
                    request.allowsCellularAccess = !wifiOnly
                    request.allowsExpensiveNetworkAccess = !wifiOnly
                    guard !readOnly, let live = jobs.first(where: { $0.id == id }), live.state == .downloading,
                          live.accountID == account?.id else { break }
                    if completedKeys.contains(block.key) || running.values.contains(where: { $0.1 == block }) { continue }
                    try DriveStorage.requireSpace(block.length + running.values.reduce(Int64(0)) { $0 + $1.1.length }, at: DriveStorage.root)
                    let task = session.downloadTask(with: request)
                    task.taskDescription = block.key
                    task.countOfBytesClientExpectsToReceive = block.length
                    task.countOfBytesClientExpectsToSend = 1024
                    // Request-level policy is applied to newly scheduled blocks.
                    running[task.taskIdentifier] = (task, block); task.resume()
                }
                if savedCounts[id, default: 0] == all.count,
                   let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .downloading {
                    jobs[index].state = .downloaded; jobs[index].message = nil
                    _ = persist(); notify("Download complete", body: "\(job.title) is ready to install in Madeira.")
                }
            } catch { fail(id, error: error) }
        }
        scheduleRetry()
        if UIApplication.shared.applicationState == .active, installer == nil,
           let job = jobs.first(where: { $0.state == .downloaded && $0.accountID == account?.id }) { install(job.id) }
    }
    func completed(id: Int, key: String?, receipt: DriveTransferDelegate.Receipt?, error: Error?) {
        running.removeValue(forKey: id); receivedBytes.removeValue(forKey: id)
        defer { if let receipt { try? FileManager.default.removeItem(at: receipt.url) }; kick() }
        guard !readOnly, let block = DriveBlock(key), let job = jobs.first(where: { $0.id == block.job }),
              block.belongs(to: job) else { return }
        do {
            if let error { throw error }
            guard let receipt else { throw DriveError.message("The download did not return a file.") }
            if receipt.status == 401 {
                guard job.state == .downloading, job.accountID == account?.id else { return }
                renewAccounts.insert(job.accountID)
                fail(job.id, error: DriveError.http(503, "renewing authorization")); return
            }
            guard (200...299).contains(receipt.status) else {
                let reader = try FileHandle(forReadingFrom: receipt.url); defer { try? reader.close() }
                throw DriveAPI.error(status: receipt.status, data: try reader.read(upToCount: 65536) ?? Data())
            }
            guard block.accepts(status: receipt.status, contentRange: receipt.range,
                                received: DriveStorage.size(receipt.url) ?? -1, total: job.files[block.file].bytes) else {
                throw DriveError.message("Drive returned an unexpected byte range. Saved blocks were kept; try Resume.")
            }
            let target = DriveStorage.block(block)
            try DriveStorage.directory(target.deletingLastPathComponent())
            if !DriveStorage.has(block) {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: receipt.url, to: target)
            }
            if completedKeys.insert(block.key).inserted {
                savedBytes[job.id, default: 0] += block.length; savedCounts[job.id, default: 0] += 1
            }
            revision += 1
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].retries = 0 }
        } catch {
            if (error as? URLError)?.code != .cancelled && job.state == .downloading { fail(job.id, error: error) }
        }
    }
    private func fail(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), ![.paused, .ready, .chooseProgram].contains(jobs[index].state) else { return }
        let retry = (error as? DriveError)?.retryable == true || ((error as? URLError).map {
            [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains($0.code)
        } ?? false)
        if case DriveError.signIn = error { jobs[index].state = .needsSignIn }
        else if retry && jobs[index].retries < 6 {
            jobs[index].retries += 1; jobs[index].state = .retryWaiting
            jobs[index].retryAt = Date().addingTimeInterval(min(300, pow(2, Double(jobs[index].retries)) * 3))
        } else { jobs[index].state = .failed }
        jobs[index].message = error.localizedDescription; _ = persist()
        for (task, block) in running.values where block.job == id { task.cancel() }
        scheduleRetry()
    }
    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard let date = jobs.filter({ $0.state == .retryWaiting }).compactMap(\.retryAt).min() else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { _ in
            MainActor.assumeIsolated { self.kick() }
        }
    }
    func install(_ id: UUID) {
        guard !readOnly, installer == nil, UIApplication.shared.applicationState == .active,
              let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .downloaded else { return }
        let job = jobs[index], drive = LibraryModel.drive
        jobs[index].state = .installing
        guard persist() else { return }
        let work = Task.detached(priority: .utility) { () throws -> (String, [String]) in
            let destination = try ExternalStoragePath.native("Google Drive/game-" + job.id.uuidString, root: drive)
            if FileManager.default.fileExists(atPath: destination.path) {
                return try DriveStorage.install(job, drive: drive)
            }
            for file in job.files {
                try Task.checkCancellation()
                let current = try await DriveAPI.shared.metadata(file.remote, account: job.accountID)
                guard current.sameContent(as: file.remote) else { throw DriveError.message("A source file changed. Cancel and download the item again.") }
            }
            return try DriveStorage.install(job, drive: drive)
        }
        installer = (id, work)
        Task {
            do {
                let (folder, programs) = try await work.value
                if let index = jobs.firstIndex(where: { $0.id == id }) {
                    jobs[index].installedFolder = folder; jobs[index].programs = programs; jobs[index].state = .chooseProgram
                    jobs[index].message = programs.isEmpty ? "No EXE, BAT or CMD was found. Add a program from the library with +." : nil
                    if persist() {
                        if programs.count == 1 { register(id, program: programs[0]) }
                        try? FileManager.default.removeItem(at: DriveStorage.job(id))
                    }
                }
            } catch is CancellationError {
                if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].state = .downloaded; _ = persist() }
            } catch { fail(id, error: error) }
            installer = nil
            if installGrace != .invalid { UIApplication.shared.endBackgroundTask(installGrace); installGrace = .invalid }
            kick()
        }
    }
    func register(_ id: UUID, program: String) {
        guard !readOnly, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].programs.contains(program),
              let folder = jobs[index].installedFolder else { return }
        let relative = folder + "/" + program
        guard FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent(relative).path) else { error = "The selected program is missing."; return }
        LibraryModel.shared.upsertDrive(id: id, title: jobs[index].title, path: relative)
        guard LibraryModel.shared.entries.contains(where: { $0.driveJobID == id }) else { error = "The game could not be saved in the library."; return }
        jobs[index].selectedProgram = program; jobs[index].state = .ready; jobs[index].message = nil; _ = persist()
    }
    private func foreground() {
        if account == nil { account = try? DriveKeychain.load()?.account }
        checkedFiles.removeAll(); kick()
    }
    private func background() {
        guard installer != nil, installGrace == .invalid else { return }
        installGrace = UIApplication.shared.beginBackgroundTask(withName: "Google Drive installation") {
            self.installer?.1.cancel()
            if self.installGrace != .invalid { UIApplication.shared.endBackgroundTask(self.installGrace); self.installGrace = .invalid }
        }
    }
    private func notify(_ title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func backgroundEvents(_ completion: @escaping () -> Void) {
        start(); self.completion = completion
        completeBackgroundEventsIfReady()
    }
    func finishBackgroundEvents() {
        eventsFinished = true
        completeBackgroundEventsIfReady()
    }
    private func completeBackgroundEventsIfReady() {
        // Schedule the next batch (including token refresh) before telling iOS
        // that the wake-up is finished. Never hold this for ZIP extraction.
        guard eventsFinished, restored, pumpTask == nil, let completion else { return }
        self.completion = nil; eventsFinished = false; completion()
    }
}

final class DriveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DriveDownloads.sessionID else { completionHandler(); return }
        DriveDownloads.shared.backgroundEvents(completionHandler)
    }
}
