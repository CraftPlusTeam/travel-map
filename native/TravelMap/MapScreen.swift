import AVFoundation
import CoreLocation
import MapKit
import SwiftUI
import TravelMapCore

struct MapScreen: View {
    @ObservedObject var store: AppStore
    @StateObject private var location = LocationService()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var position: MapCameraPosition = .region(Self.japan)
    @State private var selectedGroup: SpotGroup?
    @State private var showsLibrary = false
    @State private var showsInfo = false
    @State private var showsCamera = false
    @State private var locating = false
    @State private var draft: CaptureDraft?
    @State private var pendingImage: UIImage?
    private static let japan = MKCoordinateRegion(center: .init(latitude: 37.5, longitude: 137.5),
                                                 span: .init(latitudeDelta: 20, longitudeDelta: 20))

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
            if location.isAuthorized { UserAnnotation() }
            ForEach(store.groups) { group in
                Annotation(group.spots.first?.title ?? "景色", coordinate: group.coordinate, anchor: .bottom) {
                    Button { select(group) } label: {
                        PhotoMarker(group: group, url: group.spots.first.flatMap { store.photoURL(for: $0) })
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(group.spots.first?.title ?? "景色")、\(group.spots.count)枚の写真")
                    .accessibilityIdentifier("marker-\(group.id)")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .overlay(alignment: .top) {
            if store.isLoading {
                ProgressView("景色を読み込んでいます").padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.top, 120)
            } else if locating {
                ProgressView("現在地を確認しています…").padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.top, 120)
            }
        }
        .sheet(item: $selectedGroup) { group in
            SpotDetailSheet(group: group, store: store, isSample: store.isSample && store.scope == .discover)
        }
        .sheet(isPresented: $showsLibrary) { library }
        .sheet(isPresented: $showsInfo) { InformationView(isSample: store.isSample) }
        .fullScreenCover(isPresented: $showsCamera, onDismiss: finishCapture) {
            CameraPicker { image in
                pendingImage = image
                showsCamera = false
            }.ignoresSafeArea()
        }
        .sheet(item: $draft) { value in
            CaptureComposer(draft: value, store: store) { draft = nil }
                .interactiveDismissDisabled(store.isSaving)
        }
        .alert("確認してください", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("閉じる", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        .alert("記録しました", isPresented: Binding(
            get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("OK", role: .cancel) { store.notice = nil }
            } message: { Text(store.notice ?? "") }
        .task { await store.reload() }
        .onChange(of: store.scope) { _, _ in selectedGroup = nil }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "map.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Travel Map").font(dynamicTypeSize.isAccessibilitySize ? .headline : .title2)
                        .bold().fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("場所から、景色に出会う。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button { showsInfo = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 22)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Travel Mapについて")
                .accessibilityIdentifier("information")
            }
            Picker("表示する地図", selection: $store.scope) {
                ForEach(AppStore.Scope.allCases, id: \.self) { scope in Text(scope.rawValue).tag(scope) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("map-scope")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if store.scope == .journal && store.journalSpots.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                Label("撮った景色を、この端末の地図に。", systemImage: "lock.shield")
                    .font(.subheadline).padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { showsLibrary = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(store.scope == .journal ? "自分の足あと" : "景色をひらく").font(.headline)
                            Image(systemName: "chevron.up").font(.caption.bold())
                        }
                        Text("\(store.visibleSpots.count)枚・\(store.groups.count)スポット\(store.isSample && store.scope == .discover ? " / サンプル" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("spot-library")
                VStack(spacing: 12) {
                    Button { Task { await locate() } } label: {
                        Group {
                            if locating { ProgressView() }
                            else { Image(systemName: "location.fill").font(.system(size: 22)) }
                        }
                        .frame(width: 52, height: 52)
                        .background(.regularMaterial, in: Circle())
                    }
                    .disabled(locating)
                    .accessibilityLabel("現在地へ移動")
                    .accessibilityIdentifier("locate")
                    Button { Task { await openCamera() } } label: {
                        Image(systemName: "camera.fill").font(.system(size: 24))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 64, height: 64)
                            .background(Theme.accent, in: Circle())
                    }
                    .disabled(store.isSaving || locating)
                    .accessibilityLabel("景色を撮影して記録")
                    .accessibilityIdentifier("capture")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
    }

    private var library: some View {
        NavigationStack {
            List {
                if store.isSample && store.scope == .discover {
                    Section {
                        Label("体験用のサンプルです。写真は実際の撮影場所と一致しません。", systemImage: "sparkles")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(store.groups) { group in
                    Button {
                        showsLibrary = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            select(group)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            SpotPhoto(url: group.spots.first.flatMap { store.photoURL(for: $0) })
                                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.spots.first?.title ?? "景色").font(.headline).foregroundStyle(.primary)
                                Text("\(group.spots.count)枚の景色").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                    }.accessibilityIdentifier("spot-row-\(group.id)")
                }
                if store.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "camera").font(.system(size: 28)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("まだ記録がありません").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("カメラボタンから、最初の景色を記録しましょう。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 12)
                }
            }
            .navigationTitle(store.scope == .journal ? "端末の記録" : "景色の一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsLibrary = false } } }
            .refreshable { await store.reload() }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func select(_ group: SpotGroup) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let region = MKCoordinateRegion(center: .init(latitude: group.latitude - 0.004, longitude: group.longitude),
                                        span: .init(latitudeDelta: 0.018, longitudeDelta: 0.018))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { position = .region(region) }
        selectedGroup = group
    }

    private func locate() async {
        locating = true
        defer { locating = false }
        do {
            let value = try await location.currentLocation()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                position = .region(.init(center: value.coordinate, span: .init(latitudeDelta: 0.03, longitudeDelta: 0.03)))
            }
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            store.errorMessage = "カメラ撮影はiPhone・iPadの実機でご利用いただけます。"
            return
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed else {
            store.errorMessage = "カメラが許可されていません。設定アプリでTravel Mapのカメラを許可してください。"
            return
        }
        showsCamera = true
    }

    private func finishCapture() {
        guard let image = pendingImage else { return }
        pendingImage = nil
        let takenAt = Date()
        let locally = store.savesLocally
        Task {
            locating = true
            defer { locating = false }
            do {
                let value = try await location.currentLocation()
                let place = await LocationService.placeName(for: value.coordinate) ?? "見つけた景色"
                draft = CaptureDraft(image: image, coordinate: value.coordinate, takenAt: takenAt,
                                     suggestedTitle: place, locally: locally)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}

extension SpotGroup {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct PhotoMarker: View {
    let group: SpotGroup
    let url: URL?
    var body: some View {
        VStack(spacing: 0) {
            SpotPhoto(url: url)
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13))
                .padding(3).background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    if group.spots.count > 1 {
                        Text("\(group.spots.count)").font(.caption2.bold())
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(5).background(Theme.accent, in: Circle()).offset(x: 6, y: -6)
                    }
                }
            Image(systemName: "triangle.fill").font(.system(size: 12)).rotationEffect(.degrees(180))
                .foregroundStyle(.background).offset(y: -2)
        }.shadow(color: .black.opacity(0.18), radius: 5, y: 3)
    }
}
