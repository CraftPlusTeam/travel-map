import CoreLocation
import ImageIO
import SwiftUI
import UIKit

struct CaptureDraft: Identifiable {
    let id = UUID()
    let image: UIImage
    let coordinate: CLLocationCoordinate2D
    let takenAt: Date
    let suggestedTitle: String
    let locally: Bool
}

struct CaptureComposer: View {
    let draft: CaptureDraft
    @ObservedObject var store: AppStore
    let close: () -> Void
    @State private var title = ""
    @State private var submissionError: String?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var titleLength: Int { trimmedTitle.unicodeScalars.count }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(uiImage: draft.image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("撮影した景色")
                }
                Section("この景色の名前") {
                    TextField("タイトル", text: $title, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("capture-title")
                    Text("\(titleLength) / 100文字")
                        .font(.caption).foregroundStyle(titleLength > 100 ? .red : .secondary)
                }
                Section("撮影場所") {
                    Label(String(format: "緯度 %.5f / 経度 %.5f", draft.coordinate.latitude, draft.coordinate.longitude),
                          systemImage: "mappin.and.ellipse")
                    Text(draft.takenAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    Label(draft.locally ? "この端末だけに保存" : "みんなが見られる公開マップに投稿",
                          systemImage: draft.locally ? "lock.shield" : "globe.asia.australia")
                    Text(draft.locally
                         ? "写真と撮影場所はこの端末内に保存されます。アプリを削除すると記録も削除されます。"
                         : "写真・撮影場所・撮影日時・タイトルが公開されます。自宅など、知られたくない場所では投稿を控えてください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let submissionError {
                    Section {
                        Label(submissionError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).accessibilityIdentifier("save-error")
                    }
                }
                Section {
                    Button {
                        Task {
                            submissionError = nil
                            let saved = await store.save(title: trimmedTitle, coordinate: draft.coordinate,
                                takenAt: draft.takenAt, image: draft.image, locally: draft.locally)
                            if saved { close() }
                            else {
                                submissionError = store.errorMessage ?? "保存できませんでした。もう一度お試しください。"
                                store.errorMessage = nil
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isSaving { ProgressView().padding(.trailing, 6) }
                            Text(store.isSaving ? "保存しています…" : (draft.locally ? "この端末に記録する" : "公開して投稿する"))
                                .fontWeight(.semibold)
                            Spacer()
                        }.frame(minHeight: 44)
                    }
                    .disabled(store.isSaving || trimmedTitle.isEmpty || titleLength > 100)
                    .accessibilityIdentifier("save-capture")
                }
            }
            .navigationTitle("景色を記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { close() }.disabled(store.isSaving)
                }
            }
        }
        .onAppear { title = String(String.UnicodeScalarView(draft.suggestedTitle.unicodeScalars.prefix(100))) }
    }
}

struct CapturedPhoto {
    let image: UIImage
    let takenAt: Date

    static func captureDate(from metadata: [String: Any], timeZone: TimeZone = .current) -> Date? {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        guard let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String,
              raw.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        if let offset, offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss" + (offset == nil ? "" : "XXX")
        return formatter.date(from: raw + (offset ?? ""))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let completion: (CapturedPhoto?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (CapturedPhoto?) -> Void
        init(completion: @escaping (CapturedPhoto?) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { completion(nil); return }
            let metadata = info[.mediaMetadata] as? [String: Any] ?? [:]
            completion(CapturedPhoto(image: image, takenAt: CapturedPhoto.captureDate(from: metadata) ?? Date()))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}
