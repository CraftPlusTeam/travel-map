import Foundation
import SwiftUI
import TravelMapCore

@MainActor
final class AppStore: ObservableObject {
    enum Scope: String, CaseIterable { case discover = "見つける", journal = "端末の記録" }
    @Published var scope: Scope = .discover
    @Published private(set) var publicSpots: [Spot] = []
    @Published private(set) var journalSpots: [Spot] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var notice: String?
    private let journal: LocalJournal?
    private let client: SupabaseClient?
    private let uiTesting: Bool

    init() {
        uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        var startupError: String?
        do { journal = try LocalJournal() }
        catch { journal = nil; startupError = "端末の記録を開けませんでした。\(error.localizedDescription)" }
        let rawURL = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String ?? ""
        if !uiTesting, !rawURL.isEmpty || !key.isEmpty {
            do {
                guard let url = URL(string: rawURL) else { throw URLError(.badURL) }
                client = SupabaseClient(configuration: try SupabaseConfiguration(url: url, anonKey: key))
            } catch {
                client = nil
                startupError = "公開マップへの接続設定が無効です。現在はサンプルと端末の記録をご利用いただけます。"
            }
        } else { client = nil }
        errorMessage = startupError
        publicSpots = client == nil ? SampleSpots.make() : []
        do { journalSpots = try journal?.load() ?? [] }
        catch { errorMessage = "端末の記録を読み込めませんでした。元のデータは保持されています。" }
    }

    var isSample: Bool { client == nil }
    var visibleSpots: [Spot] { scope == .journal ? journalSpots : publicSpots }
    var groups: [SpotGroup] { SpotGrouping.groups(from: visibleSpots) }
    var savesLocally: Bool { scope == .journal || isSample }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let client { publicSpots = try await client.fetchSpots() }
            journalSpots = try journal?.load() ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    func photoURL(for spot: Spot) -> URL? {
        if let url = URL(string: spot.photoPath), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return url }
        if let local = journal?.photoURL(for: spot.photoPath) { return local }
        return client?.photoURL(for: spot.photoPath)
    }

    func save(title: String, coordinate: CLLocationCoordinate2D, takenAt: Date, image: UIImage, locally: Bool) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        guard let jpeg = image.journalJPEG() else {
            errorMessage = "写真を保存用に変換できませんでした。もう一度撮影してください。"
            return false
        }
        do {
            if locally {
                guard let journal else { throw CocoaError(.fileWriteNoPermission) }
                let spot = try journal.save(title: title, latitude: coordinate.latitude,
                    longitude: coordinate.longitude, takenAt: takenAt, jpegData: jpeg)
                journalSpots.insert(spot, at: 0)
                scope = .journal
                notice = "この端末に景色を記録しました"
            } else {
                guard let client else { throw URLError(.notConnectedToInternet) }
                let spot = try await client.createSpot(title: title, latitude: coordinate.latitude,
                    longitude: coordinate.longitude, takenAt: takenAt, jpegData: jpeg)
                publicSpots.insert(spot, at: 0)
                notice = "公開マップに景色を投稿しました"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

import CoreLocation
import UIKit

enum SampleSpots {
    static func make(now: Date = Date()) -> [Spot] {
        let rows: [(String, Double, Double, String, TimeInterval)] = [
            ("江の島の朝焼け", 35.30335, 139.52025, "enoshima2", -3 * 3_600),
            ("海を見渡す場所", 35.30328, 139.52016, "enoshima3", -3 * 86_400),
            ("夕暮れの海岸", 35.30331, 139.52024, "enoshima4", -20 * 86_400),
            ("河口湖のほとり", 35.51720, 138.75110, "kawaguchiko", -86_400),
            ("京都を歩く", 34.99480, 135.78500, "kiyomizu", -7 * 86_400),
            ("美瑛の丘", 43.49680, 142.49690, "biei", -4 * 86_400),
            ("東京の夜景", 35.68970, 139.69170, "shinjuku", -2 * 86_400)
        ]
        return rows.enumerated().map { index, row in
            Spot(id: "sample-\(index)", createdAt: now.addingTimeInterval(row.4), userID: nil,
                 title: row.0, latitude: row.1, longitude: row.2,
                 photoPath: "https://picsum.photos/seed/\(row.3)/900/700",
                 takenAt: now.addingTimeInterval(row.4))
        }
    }
}
