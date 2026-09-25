import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static let farRelayControllerProfile = UTType(
        exportedAs: "com.sebb7.farrelay.controller-profile",
        conformingTo: .json
    )
}

enum FarRelayProfileFileName {
    static let fileExtension = "fr"

    static func baseName(for profileName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_ ")
        )
        let filtered = profileName.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let base = cleaned.isEmpty ? "FarRelay-Controller-Profile" : cleaned
        return String(base.prefix(80))
    }
}

enum FarRelayProfileFileImport {
    static func canOpen(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return url.pathExtension.compare(
            FarRelayProfileFileName.fileExtension,
            options: [.caseInsensitive]
        ) == .orderedSame
    }

    static func decode(_ url: URL) throws -> FarRelayControllerProfileManifest {
        guard canOpen(url) else {
            throw FarRelayProfileFileError.invalidProfile(
                "FarRelay can only import .fr controller profile files."
            )
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try FarRelayProfileCodec.decode(Data(contentsOf: url))
    }
}

struct FarRelayProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.farRelayControllerProfile] }
    static var writableContentTypes: [UTType] { [.farRelayControllerProfile] }

    let manifest: FarRelayControllerProfileManifest

    init(manifest: FarRelayControllerProfileManifest) {
        self.manifest = manifest
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FarRelayProfileFileError.malformedFile
        }
        manifest = try FarRelayProfileCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(
            regularFileWithContents: try FarRelayProfileCodec.encode(manifest)
        )
    }
}

enum FarRelayProfileSharing {
    static func temporaryFileURL(
        for manifest: FarRelayControllerProfileManifest
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarRelayProfiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileName = FarRelayProfileFileName.baseName(for: manifest.profile.name)
            + "."
            + FarRelayProfileFileName.fileExtension
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try FarRelayProfileCodec.encode(manifest).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
struct FarRelayProfileShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
