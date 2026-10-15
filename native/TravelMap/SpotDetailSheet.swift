import MapKit
import SwiftUI
import TravelMapCore

struct SpotPhoto: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
                        case .failure: placeholder(symbol: "photo")
                        default: placeholder(symbol: "photo.on.rectangle.angled")
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
    }
    private func placeholder(symbol: String) -> some View {
        ZStack {
            Theme.canvas
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

struct SpotDetailSheet: View {
    let group: SpotGroup
    @ObservedObject var store: AppStore
    let isSample: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var period: FreshnessPeriod = .all
    @State private var place = ""
    @State private var fullscreen = false
    @State private var detent: PresentationDetent = .fraction(0.58)

    private var spot: Spot { group.spots[min(index, group.spots.count - 1)] }
    private var filtered: [Spot] { period.filter(group.spots, now: Date(), calendar: .current) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(spot.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("spot-title")
                        Label(place.isEmpty ? "撮影場所を確認中…" : place, systemImage: "mappin.and.ellipse")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let date = spot.takenAt {
                            Label(date.formatted(date: .abbreviated, time: .shortened) + " 撮影", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if isSample {
                            Label("サンプルの写真・撮影場所です", systemImage: "sparkles")
                                .font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    Button { fullscreen = true } label: {
                        SpotPhoto(url: store.photoURL(for: spot))
                            .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .padding(12).foregroundStyle(.white)
                                    .background(.black.opacity(0.55), in: Circle()).padding(12)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("写真を全画面で表示")
                    .accessibilityIdentifier("expand-photo")
                    if group.spots.count > 1 {
                        Picker("写真の期間", selection: $period) {
                            Text("今日").tag(FreshnessPeriod.today)
                            Text("今週").tag(FreshnessPeriod.week)
                            Text("すべて").tag(FreshnessPeriod.all)
                        }.pickerStyle(.segmented).accessibilityIdentifier("photo-period")
                        if filtered.isEmpty {
                            Text("この期間の写真はありません").foregroundStyle(.secondary).padding(.vertical)
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(filtered) { photo in
                                        Button { index = group.spots.firstIndex(where: { $0.id == photo.id }) ?? 0 } label: {
                                            VStack(spacing: 5) {
                                                SpotPhoto(url: store.photoURL(for: photo))
                                                    .frame(width: 84, height: 76)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                                        .stroke(photo.id == spot.id ? Theme.accent : .clear, lineWidth: 3))
                                                Text((photo.takenAt ?? photo.createdAt).formatted(.relative(presentation: .named)))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain).accessibilityLabel(photo.title)
                                            .accessibilityAddTraits(photo.id == spot.id ? .isSelected : [])
                                    }
                                }.padding(3)
                            }.scrollIndicators(.hidden)
                        }
                    }
                    HStack(spacing: 16) {
                        Button {
                            let item = MKMapItem(placemark: MKPlacemark(coordinate: group.coordinate))
                            item.name = spot.title
                            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                        } label: { Label("ここへ行く", systemImage: "arrow.triangle.turn.up.right.diamond") }
                            .buttonStyle(.bordered).controlSize(.large)
                        ShareLink(item: shareText) { Label("共有", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("\(group.spots.count)枚の景色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("close-detail")
                }
            }
        }
        .presentationDetents([.fraction(0.58), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.58)))
        .fullScreenCover(isPresented: $fullscreen) {
            PhotoViewer(spots: group.spots, index: $index, store: store, isSample: isSample)
        }
        .task(id: group.id) {
            place = await LocationService.placeName(for: group.coordinate)
                ?? String(format: "%.4f, %.4f", group.latitude, group.longitude)
        }
    }

    private var shareText: String {
        "\(isSample ? "【サンプル】" : "")\(spot.title)\nhttps://maps.apple.com/?ll=\(spot.latitude),\(spot.longitude)"
    }
}

struct PhotoViewer: View {
    let spots: [Spot]
    @Binding var index: Int
    @ObservedObject var store: AppStore
    let isSample: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(spots.enumerated()), id: \.element.id) { offset, spot in
                    VStack(spacing: 20) {
                        Spacer(minLength: 44)
                        SpotPhoto(url: store.photoURL(for: spot), contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(false).accessibilityLabel(spot.title)
                        Text(spot.title).font(.headline).foregroundStyle(.white)
                        if isSample { Text("サンプル写真").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                        Spacer(minLength: 44)
                    }.padding(.horizontal, 12).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .accessibilityIdentifier("photo-pager")
            VStack {
                HStack {
                    Text("\(index + 1) / \(spots.count)").font(.subheadline.monospacedDigit())
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                            .background(.white.opacity(0.15), in: Circle())
                    }.accessibilityLabel("全画面写真を閉じる").accessibilityIdentifier("close-viewer")
                }
                Spacer()
                HStack {
                    Button { index = max(0, index - 1) } label: {
                        Label("前の写真", systemImage: "chevron.left").padding(12)
                    }.disabled(index == 0).accessibilityIdentifier("previous-photo")
                    Spacer()
                    Button { index = min(spots.count - 1, index + 1) } label: {
                        Label("次の写真", systemImage: "chevron.right").padding(12)
                    }.disabled(index == spots.count - 1).accessibilityIdentifier("next-photo")
                }.padding(.bottom, 24)
            }.padding(20).foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }
}
