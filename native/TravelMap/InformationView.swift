import SwiftUI

struct InformationView: View {
    let isSample: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "map.fill").font(.largeTitle).foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text("場所から、景色に出会う。").font(.title2.bold())
                        Text("立っていた場所と、見つけた景色を一緒に。地図の上で、自分の旅を振り返れます。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("端末の記録") {
                    Label("写真と撮影場所は、この端末内だけに保存されます。", systemImage: "lock.shield")
                    Text("アプリを削除すると記録も削除されます。大切な写真は別の場所にも保管してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if isSample {
                    Section("サンプルについて") {
                        Text("「見つける」では操作を体験できるサンプルを表示しています。写真は実際の撮影場所と一致しません。")
                        Text("いま撮影した景色は「端末の記録」に保存できます。公開投稿は現在利用できません。")
                    }
                } else {
                    Section("公開マップ") {
                        Text("「見つける」に投稿した写真・撮影場所・撮影日時・タイトルは公開されます。「端末の記録」に保存した景色は公開されません。")
                    }
                }
                Section("写真と位置情報") {
                    Text("カメラは撮影ボタンを押したときだけ使います。位置情報は現在地の表示や、撮影場所を記録するときに確認します。")
                    Text("保存する写真から余分な撮影情報を取り除きます。記録の撮影場所と撮影日時は別に保存されます。")
                }
                Section {
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                    Link("プロジェクトを開く", destination: URL(string: "https://github.com/CraftPlusTeam/travel-map")!)
                }
            }
            .navigationTitle("Travel Mapについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() }.accessibilityIdentifier("close-info") }
            }
        }
    }
}
