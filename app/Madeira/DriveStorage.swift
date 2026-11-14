// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import CryptoKit

enum DriveStorage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoogleDrive", isDirectory: true)
    }
    static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    static func directory(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #endif
    }
    static func job(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func block(_ block: DriveBlock) -> URL {
        job(block.job).appendingPathComponent("blocks/\(block.file)/\(block.offset).part")
    }
    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
    static func has(_ block: DriveBlock) -> Bool { size(self.block(block)) == block.length }
    static func blocks(_ job: DriveJob) -> [DriveBlock] {
        var result: [DriveBlock] = []
        for (index, file) in job.files.enumerated() {
            var offset: Int64 = 0
            while offset < file.bytes {
                let length = min(DriveBlock.size, file.bytes - offset)
                result.append(DriveBlock(job: job.id, file: index, offset: offset, length: length)); offset += length
            }
        }
        return result
    }
    static func available(_ url: URL) throws -> Int64 {
        #if os(iOS)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage { return bytes }
        #endif
        return (try FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    static func requireSpace(_ bytes: Int64, at url: URL) throws {
        let spare: Int64 = 256 * 1024 * 1024
        guard bytes >= 0, bytes <= Int64.max - spare, try available(url) >= bytes + spare else {
            throw DriveError.message("Not enough storage. Free space and resume this download.")
        }
    }
    /// Keep durable blocks until installation succeeds, including after an interrupted assembly.
    static func assemble(_ plan: DriveFilePlan, index: Int, job: UUID, to output: URL) throws {
        let fm = FileManager.default
        try directory(output.deletingLastPathComponent())
        let temporary = output.appendingPathExtension("assembling")
        if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw DriveError.message("Could not create the downloaded file.") }
        let writer = try FileHandle(forWritingTo: temporary)
        var digest = Insecure.MD5(); var offset: Int64 = 0
        do {
            while offset < plan.bytes {
                try Task.checkCancellation()
                let length = min(DriveBlock.size, plan.bytes - offset)
                let part = DriveBlock(job: job, file: index, offset: offset, length: length)
                guard has(part) else { throw DriveError.message("A saved download block is missing. Resume downloading.") }
                let reader = try FileHandle(forReadingFrom: block(part))
                defer { try? reader.close() }
                var count: Int64 = 0
                while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    count += Int64(data.count); digest.update(data: data); try writer.write(contentsOf: data)
                }
                guard count == length else { throw DriveError.message("A saved download block is damaged.") }
                offset += length
            }
            try writer.synchronize(); try writer.close()
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = plan.remote.md5Checksum, hash != expected.lowercased() {
                // Only this file's blocks are invalid; other files remain resumable.
                let parts = block(DriveBlock(job: job, file: index, offset: 0, length: 1)).deletingLastPathComponent()
                if fm.fileExists(atPath: parts.path) { try fm.removeItem(at: parts) }
                throw DriveError.message("A file failed its checksum. Resume to download that file again.")
            }
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: temporary, to: output)
        } catch {
            try? writer.close(); try? fm.removeItem(at: temporary); throw error
        }
    }
    static func programs(in folder: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var programs: [String] = []
        for case let url as URL in walk {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw DriveError.message("A game contains an unsupported symbolic link.") }
            if values.isRegularFile == true, ["exe", "bat", "cmd"].contains(url.pathExtension.lowercased()) {
                programs.append(String(url.path.dropFirst(folder.path.count + 1)))
            }
        }
        return programs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func install(_ job: DriveJob, drive: URL) throws -> (String, [String]) {
        let fm = FileManager.default
        let relative = "Google Drive/game-" + job.id.uuidString
        let destination = try ExternalStoragePath.native(relative, root: drive)
        // Crash after rename, before saving the job: recover the completed installation.
        if fm.fileExists(atPath: destination.path) { return (relative, try programs(in: destination)) }
        try directory(self.job(job.id)); try directory(drive)
        let staging = self.job(job.id).appendingPathComponent("installation", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try directory(staging)
        try requireSpace(job.totalBytes, at: drive)
        if job.source.isZIP {
            let archive = self.job(job.id).appendingPathComponent("archive.zip")
            try assemble(job.files[0], index: 0, job: job.id, to: archive)
            let entries = try ItchArchive.entries(archive)
            try DrivePaths.validate(files: entries.filter { !$0.directory }.map {
                DriveFilePlan(remote: job.files[0].remote, path: $0.name, bytes: Int64(clamping: $0.size))
            }, directories: entries.filter(\.directory).map(\.name))
            var unpacked: Int64 = 0
            for entry in entries {
                _ = try DrivePaths.relative(entry.name)
                guard entry.size <= UInt64(Int64.max), unpacked <= Int64.max - Int64(entry.size) else { throw DriveError.message("Invalid ZIP size.") }
                unpacked += Int64(entry.size)
            }
            try requireSpace(unpacked, at: drive)
            try ItchArchive.unpack(archive, to: staging)
        } else {
            for directory in job.directories { try self.directory(staging.appendingPathComponent(try DrivePaths.relative(directory))) }
            for (index, plan) in job.files.enumerated() {
                try assemble(plan, index: index, job: job.id, to: staging.appendingPathComponent(try DrivePaths.relative(plan.path)))
            }
        }
        let programs = try self.programs(in: staging)
        try Task.checkCancellation()
        try directory(destination.deletingLastPathComponent())
        try fm.moveItem(at: staging, to: destination)
        return (relative, programs)
    }
}
