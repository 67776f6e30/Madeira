// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

extension LibraryModel {
    @MainActor func upsertDrive(id: UUID, title: String, path: String) {
        var entry = entries.first { $0.driveJobID == id } ?? LibraryEntry(title: title, relativePath: path, bits: 0)
        entry.driveJobID = id; entry.relativePath = path; entry.metadataChecked = nil
        if let inspected = try? Self.inspect(Self.drive.appendingPathComponent(path)) {
            entry.bits = inspected.bits; entry.graphicsAPI = inspected.graphicsAPI
        }
        save(entry)
    }
}

@MainActor final class DrivePresentation: ObservableObject {
    static let shared = DrivePresentation()
    @Published var showing = false
}

struct DriveSheets: ViewModifier {
    var open: (LibraryEntry) -> Void = { _ in }
    @ObservedObject private var presentation = DrivePresentation.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: $presentation.showing) {
            DriveLibraryView { entry in
                presentation.showing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(entry) }
            }
        }
    }
}

struct DriveGamesSection: View {
    var search: String
    var open: (LibraryEntry) -> Void
    @ObservedObject private var downloads = DriveDownloads.shared
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Google Drive", systemImage: "externaldrive.badge.icloud").font(.headline)
                Spacer()
                Button("Browse & Downloads") { DrivePresentation.shared.showing = true }
            }
            if let selection = downloads.selection { Text(selection.displayPath).font(.caption).foregroundStyle(.secondary) }
            else { Text("Connect Google Drive and choose your games folder.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(library.entries.filter { $0.driveJobID != nil && $0.listedInLibrary && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { entry in
                Button { open(entry) } label: {
                    HStack { Image(systemName: "gamecontroller"); Text(entry.title); Spacer(); Image(systemName: "chevron.right") }
                }.buttonStyle(.borderless)
            }
            let pending = downloads.jobs.filter { $0.state != .ready }.count
            if pending > 0 { Text("\(pending) download(s) — open Downloads for progress").font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DriveSettingsSection: View {
    @ObservedObject private var downloads = DriveDownloads.shared
    @State private var showing = false
    var body: some View {
        Section {
            Button { showing = true } label: { Label("Google Drive and downloads", systemImage: "externaldrive.badge.icloud") }
            if let account = downloads.account { Text(account.email).foregroundStyle(.secondary) }
            if let selection = downloads.selection { Text(selection.displayPath).font(.caption) }
        } header: { Text("Google Drive") } footer: { Text("Download ZIP files or game folders from your Google Drive.") }
        .sheet(isPresented: $showing) { DriveLibraryView(open: nil) }
    }
}

struct DriveLibraryView: View {
    var open: ((LibraryEntry) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = DriveDownloads.shared
    @State private var folders: [DriveRemoteFile] = [.root]
    @State private var items: [DriveRemoteFile] = []
    @State private var loading = false
    @State private var folderError: String?
    @State private var refreshID = UUID()
    @State private var cancelJob: UUID?
    @State private var disconnecting = false
    private var current: DriveRemoteFile { folders.last ?? .root }
    private var location: String { folders.map(\.name).joined(separator: " / ") }
    private var requestID: String { (downloads.account?.id ?? "") + ":" + current.id + ":" + refreshID.uuidString }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let account = downloads.account {
                        Text(account.email)
                        Button("Reconnect Google account") { Task { await downloads.signIn() } }.disabled(downloads.busy)
                        Button("Disconnect", role: .destructive) { disconnecting = true }.disabled(downloads.busy)
                    } else {
                        Button("Sign in with Google") { Task { await downloads.signIn() } }.disabled(downloads.busy)
                    }
                    if !DriveOAuth.configured {
                        Text("This build needs a Google OAuth client ID and URL scheme. See docs/GOOGLE_DRIVE.md.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Download over Wi-Fi only", isOn: $downloads.wifiOnly)
                }
                if downloads.account != nil {
                    Section {
                        if let selection = downloads.selection { Text("Library folder: " + selection.displayPath).font(.footnote) }
                        HStack {
                            Button("My Drive") { folders = [.root] }
                            Spacer()
                            Button("Up") { if folders.count > 1 { folders.removeLast() } }.disabled(folders.count < 2)
                        }.buttonStyle(.borderless)
                        Text(location).font(.caption).textSelection(.enabled)
                        Button("Use this folder") { downloads.select(current, path: location) }.disabled(loading)
                        if current.id != "root" {
                            Button("Download this folder as a game") { Task { await downloads.enqueue(current) } }
                                .disabled(downloads.busy || loading)
                        }
                        if loading { ProgressView("Loading files…") }
                        if let folderError {
                            Text(folderError).foregroundStyle(.red)
                            Button("Retry listing") { refreshID = UUID() }
                        }
                        ForEach(items) { file in
                            HStack {
                                if file.isFolder {
                                    Button { folders.append(file) } label: { Label(file.name, systemImage: "folder") }
                                } else {
                                    Label(file.name, systemImage: file.isZIP ? "doc.zipper" : "doc")
                                }
                                Spacer()
                                if file.isFolder || file.isZIP {
                                    Button { Task { await downloads.enqueue(file) } } label: { Image(systemName: "arrow.down.circle") }
                                        .accessibilityLabel("Download " + file.name).disabled(downloads.busy)
                                }
                            }.buttonStyle(.borderless)
                            if let bytes = file.byteCount { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    } header: { Text("Choose a Drive folder") } footer: {
                        Text("ZIP files are unpacked after downloading. A game folder keeps all its subfolders. Shortcuts and Google documents cannot be downloaded as games.")
                    }
                }
                if downloads.busy { Section { ProgressView("Preparing…") } }
                Section("Downloads") {
                    if downloads.jobs.isEmpty { Text("No downloads yet").foregroundStyle(.secondary) }
                    ForEach(downloads.jobs) { job in jobRow(job) }
                }
                Section {
                    Text("Transfers can continue while the screen is locked. Force-quitting Madeira cancels active transfers; reopen the app and resume. Completed 128 MB blocks are kept. Installation finishes while Madeira is open.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Google Drive")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                downloads.start()
                if let selection = downloads.selection, selection.accountID == downloads.account?.id {
                    folders = selection.folder.id == "root" ? [.root] : [.root, selection.folder]
                }
            }
            .task(id: requestID) { await load() }
            .refreshable { refreshID = UUID() }
            .alert("Google Drive", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
                Button("OK", role: .cancel) { downloads.error = nil }
            } message: { Text(downloads.error ?? "") }
            .confirmationDialog("Cancel this download and delete its saved blocks?", isPresented: Binding(get: { cancelJob != nil }, set: { if !$0 { cancelJob = nil } })) {
                Button("Cancel download", role: .destructive) { if let id = cancelJob { downloads.cancel(id) }; cancelJob = nil }
            }
            .confirmationDialog("Disconnect Google Drive? Downloads will pause and installed games will stay.", isPresented: $disconnecting) {
                Button("Disconnect", role: .destructive) { Task { await downloads.disconnect(); items = []; folders = [.root] } }
            }
        }
    }
    @ViewBuilder private func jobRow(_ job: DriveJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.title).font(.headline)
            Text(job.state.title).font(.subheadline)
            if [.downloading, .paused, .retryWaiting, .failed, .needsSignIn].contains(job.state) {
                let done = downloads.downloaded(job)
                ProgressView(value: Double(done), total: Double(max(1, job.totalBytes)))
                Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))")
                    .font(.caption).monospacedDigit()
            }
            if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if job.state == .downloading || job.state == .retryWaiting { Button("Pause") { downloads.pause(job.id) } }
                if [.paused, .failed, .needsSignIn].contains(job.state) { Button("Resume") { downloads.resume(job.id) } }
                if job.state == .downloaded { Button("Install") { downloads.install(job.id) } }
                if job.state == .installing { ProgressView() }
                if job.installedFolder == nil && job.state != .installing { Button("Cancel", role: .destructive) { cancelJob = job.id } }
                if job.state == .ready, let open, let entry = LibraryModel.shared.entries.first(where: { $0.driveJobID == job.id }) {
                    Button("Game details") { open(entry) }
                }
            }.buttonStyle(.borderless)
            if job.state == .chooseProgram || job.state == .ready {
                Menu(job.state == .ready ? "Change program" : "Choose program") {
                    ForEach(job.programs, id: \.self) { path in Button(path) { downloads.register(job.id, program: path) } }
                }.disabled(job.programs.isEmpty)
                if let folder = job.installedFolder { Text("Madeira / wine / drive_c / " + folder).font(.caption).textSelection(.enabled) }
            }
        }.padding(.vertical, 4)
    }
    private func load() async {
        let id = requestID, folder = current
        guard let account = downloads.account else { items = []; return }
        loading = true; folderError = nil; items = []
        defer { if id == requestID { loading = false } }
        do {
            let files = try await DriveAPI.shared.list(folder, account: account.id)
            guard !Task.isCancelled, id == requestID else { return }; items = files
        } catch { if !Task.isCancelled, id == requestID { folderError = error.localizedDescription } }
    }
}
