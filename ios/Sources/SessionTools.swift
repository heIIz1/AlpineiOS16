// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit
import Darwin

enum SessionTools {
    static let shared = URL.documentsDirectory.appendingPathComponent("Shared", isDirectory: true)

    static func send(_ action: String) throws {
        try Data("\(action) \(UUID().uuidString)".utf8).write(
            to: shared.appendingPathComponent(".alpineios-desktop-action"), options: .atomic)
    }

    static func addFile(_ source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folder = shared.appendingPathComponent("Files", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = folder.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(sourceName) (\(suffix))")
            if !ext.isEmpty { destination.appendPathExtension(ext) }
            suffix += 1
        }
        try fm.copyItem(at: source, to: destination)
    }

    static let snapshot = URL.applicationSupportDirectory.appendingPathComponent("AlpineiOS/disk-snapshot.img")

    static func copyDisk(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".disk-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        if clonefile(source.path, temporary.path, 0) != 0 {
            try fm.copyItem(at: source, to: temporary)
        }
        if rename(temporary.path, destination.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
