import Foundation
import UIKit
import TravelMapCore

/// Photos and metadata stay in the app sandbox. No cloud request is made here.
@MainActor
final class LocalJournal {
    private let directory: URL
    private let metadataURL: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelJournal", isDirectory: true)
        self.metadataURL = self.directory.appendingPathComponent("spots.json")
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var journalDirectory = self.directory
        try journalDirectory.setResourceValues(values)
    }

    func load() throws -> [Spot] {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Spot].self, from: Data(contentsOf: metadataURL))
    }

    func save(title: String, latitude: Double, longitude: Double, takenAt: Date, jpegData: Data) throws -> Spot {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(title.unicodeScalars.count), latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !jpegData.isEmpty, jpegData.count <= 10 * 1_024 * 1_024 else {
            throw JournalError.invalidRecord
        }
        // Read before writing a photo so a corrupt journal never gets overwritten.
        var records = try load()
        let id = UUID().uuidString
        let filename = id + ".jpg"
        let photoURL = directory.appendingPathComponent(filename)
        let spot = Spot(id: id, createdAt: Date(), userID: nil, title: title,
                        latitude: latitude, longitude: longitude,
                        photoPath: filename, takenAt: takenAt)
        try jpegData.write(to: photoURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            records.insert(spot, at: 0)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: metadataURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? fileManager.removeItem(at: photoURL)
            throw error
        }
        return spot
    }

    func photoURL(for path: String) -> URL? {
        // A saved filename is never allowed to escape the journal directory.
        guard !path.contains("/"), !path.contains("\\"), path.hasSuffix(".jpg"),
              UUID(uuidString: String(path.dropLast(4))) != nil else { return nil }
        let url = directory.appendingPathComponent(path)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

enum JournalError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "記録を保存できません。タイトル・撮影場所・写真を確認してください。" }
}

extension UIImage {
    /// Re-rendering strips EXIF metadata, normalizes orientation and limits upload size.
    func journalJPEG() -> Data? {
        let scale = min(1, 2_048 / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }.jpegData(compressionQuality: 0.85)
    }
}
