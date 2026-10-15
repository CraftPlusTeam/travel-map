import XCTest
import UIKit
@testable import TravelMap

@MainActor
final class LocalJournalTests: XCTestCase {
    func testSavedRecordSurvivesReopeningJournalAndKeepsPhoto() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try LocalJournal(directory: directory)
        let bytes = try XCTUnwrap(testImage().journalJPEG())
        let record = try journal.save(title: "  旅の景色  ", latitude: 35.3, longitude: 139.5,
                                      takenAt: Date(timeIntervalSince1970: 1_700_000_000), jpegData: bytes)
        let reopened = try LocalJournal(directory: directory)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, record.id)
        XCTAssertEqual(loaded.first?.title, "旅の景色")
        XCTAssertEqual(loaded.first?.takenAt, record.takenAt)
        let photo = try XCTUnwrap(reopened.photoURL(for: record.photoPath))
        XCTAssertEqual(try Data(contentsOf: photo), bytes)
        XCTAssertNil(reopened.photoURL(for: "../outside.jpg"))
        XCTAssertNil(reopened.photoURL(for: "https://example.com/a.jpg"))
    }

    func testCorruptMetadataIsPreservedAndNoPhotoIsAdded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try LocalJournal(directory: directory)
        let metadata = directory.appendingPathComponent("spots.json")
        let original = Data("corrupted".utf8)
        try original.write(to: metadata)
        XCTAssertThrowsError(try journal.save(title: "景色", latitude: 35, longitude: 139,
                                              takenAt: Date(), jpegData: Data([1, 2, 3])))
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["spots.json"])
    }

    func testInvalidCoordinatesAndEmptyTitleAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try LocalJournal(directory: directory)
        XCTAssertThrowsError(try journal.save(title: " ", latitude: 35, longitude: 139,
                                              takenAt: Date(), jpegData: Data([1])))
        XCTAssertThrowsError(try journal.save(title: "景色", latitude: .nan, longitude: 139,
                                              takenAt: Date(), jpegData: Data([1])))
        XCTAssertEqual(try journal.load().count, 0)
    }

    func testJPEGNormalizesLargeImages() throws {
        let image = testImage(size: CGSize(width: 4_000, height: 3_000))
        let data = try XCTUnwrap(image.journalJPEG())
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, 2_048)
        XCTAssertEqual(decoded.size.height, 1_536)
        XCTAssertLessThan(data.count, 10 * 1_024 * 1_024)
    }

    private func testImage(size: CGSize = CGSize(width: 64, height: 48)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
