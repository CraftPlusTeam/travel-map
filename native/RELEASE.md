# Travel Map のTestFlight配布

| 項目 | 値 |
| --- | --- |
| Bundle ID / SKU | `com.craftplusteam.travelmap` |
| Apple Developer Team | `BTYVH3R392`（akihiko ootuka） |
| App名 / 主言語 | `Travel Map` / 日本語 (`ja`) |
| 初回version / build | `1.0.0` / `1` |
| Xcode project / scheme | `TravelMap.xcodeproj` / `TravelMap` |

配布対象は `native/` のSwift版です。既存Expo版とは保存形式とインストール先が異なります。Swift版への既存端末データの自動移行はありません。

## 登録と認証

Bundle IDはTeam `BTYVH3R392` に登録済みです。既存レコードを確認し、必要な場合だけ登録するには `ruby Scripts/release/release.rb register-bundle` を使います。同じ識別子を再登録したり、証明書を失効したりする処理は含みません。

初回Appレコードは[App Store ConnectのWeb画面](https://appstoreconnect.apple.com/apps)で上表の値を使い、iOS・Full Accessとして作成します。[AppleのApps API](https://developer.apple.com/documentation/appstoreconnectapi/apps)は新規appレコードの作成をサポートしていません。[新規アプリ登録手順](https://developer.apple.com/jp/help/app-store-connect/create-an-app-record/add-a-new-app/)を参照してください。

Macの権限付きApp Store Connect APIキーを使います。以下の環境変数を、Git外のパーミッション `0600` の設定ファイルまたはprivateラッパーから渡します。値をソース・Issue・ログ・シェルのトレースへ記録しません。

- `ASC_KEY_PATH`: `.p8` 秘密鍵の絶対パス
- `ASC_KEY_ID`: そのキーのID
- `ASC_ISSUER_ID`: 同じApple Teamのissuer ID
- `ASC_JWT_HELPER`: 既存のprivateなRuby JWT生成スクリプト。読取API用の任意設定で、指定しない場合は上の3変数からトークンを生成します。

署名に使う証明書と秘密鍵はMacのKeychainで使用可能にしておきます。専用Keychainを使う場合は `TRAVELMAP_SIGNING_KEYCHAIN` を指定し、検索リストやdefault Keychainの元の設定を保存して作業後に復元します。既存証明書を失効したり、既存Keychainの内容を消したりしないでください。Keychainパスワード・P12・プロファイル・署名済みIPAはGit外で保持します。

## ビルドと検証

Xcode 26以降・iOS 26以降のSDKとXcodeGenが必要です。以下は `native/` で実行します。`.build-output/` はGit管理から除外し、配布物とログはprivateな保存先として扱います。`TRAVELMAP_RELEASE_DIR` で保存先を変更できます。Gitから切り離したMac作業コピーをビルドする場合は `TRAVELMAP_NATIVE_DIR` にその `native/` 相当のディレクトリを指定し、実際に同期したcommit SHAを `TRAVELMAP_SOURCE_SHA` に渡します。

```sh
set +x
# このファイルには上記の認証環境変数をexportする設定のみを置く。
. "$HOME/.config/travel-map-release.env"
export TRAVELMAP_VERSION=1.0.0 TRAVELMAP_BUILD=1
# 実際に同期した、レビュー済みソースの40桁commit SHAを指定する。
export TRAVELMAP_SOURCE_SHA="$(git rev-parse HEAD)"

xcodegen generate
ruby Scripts/release/test_release.rb
ruby Scripts/release/release.rb preflight
ruby Scripts/release/release.rb archive
ruby Scripts/release/release.rb export
ruby Scripts/release/release.rb verify
```

`archive` はApple Developmentによる自動署名Archiveを作り、Bundle / Team / version / build・署名・プライバシーマニフェストを確認します。`export` は `method=app-store-connect` で配布IPAを書き出します。`destination=export` のため、この段階ではアップロードしません。

`verify` はIPAのBundle / Team / version / build、codesign、App Store用プロファイル、プロファイル有効期限とSHA-256を確認し、Archive時のsource SHAと一緒に保存先の `verified-ipa.json` へ結果を書きます。開発用の `ProvisionedDevices`、`get-task-allow=true`、`XTL-`識別子や別TeamのIPAは通しません。既存のArchiveやIPAを暗黙に上書きせず、次回配布には新しいbuild番号を使います。

## アップロードとApple側の処理確認

初回Appレコードが作成済みであることを `preflight` で確認します。`appRecordRequired=true` ならWeb登録が未完了です。

```sh
# verifyの結果と、今回レビューした配布物のSHAが一致することを確認して指定する。
export TRAVELMAP_EXPECTED_IPA_SHA256='<verifyで確認したSHA-256>'
ruby Scripts/release/release.rb upload
ruby Scripts/release/release.rb status
```

`upload` はAppレコードのBundle / SKU / 主言語とIPAのSHAを再照合してから、[Appleのアップロードツール](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)に送ります。成功済みの同じIPAは再送せず、`status` でApple側の処理を確認します。通信結果が不明な場合も、同じbuild番号を再送する前にApple側の状態を確認してください。

`status` は対象version / buildに限定し、`processingState=VALID`、`expired=false`、`internalBuildState=READY_FOR_BETA_TESTING` または `IN_BETA_TESTING` になった時だけ成功終了します。アップロード成功だけではTestFlight準備完了と扱いません。暗号化申告が必要な状態なら、その内容を確認して解消します。

初回テストでは、地図と一覧の表示、100m以内のスポット集約、今日／今週／すべての期間絞り込み、写真の全画面表示・横ページ切替、体験用データがサンプルと明示されることを確認対象にします。実機では撮影、GPS取得、タイトル入力と端末保存、再起動後の保持、カメラ／位置情報の権限拒否時の案内を確認対象にします。実際の撮影・GPS精度・権限拒否や設定変更と、公開バックエンドへの接続・投稿・ネットワーク切断後の再試行は未検証です。一般公開・外部審査提出・テスターの追加やメール招待は、この配布手順には含みません。

## 結果の記録

Issue / PRにはsource commit、Xcode / SDK、version / build、IPA SHA-256、アップロード結果、Apple側の処理状態と未検証事項を記録します。認証ID・JWT・秘密鍵・Cookie・rawな署名診断ファイルは載せません。ツール実行ログは認証値を除去しますが、配布物やrawなXcode診断の公開には使わず、必要な結果だけ抜粋します。

## 2026-10-16 の署名ビルド

| 項目 | 確認結果 |
| --- | --- |
| Archiveのアプリsource | `8ac2d4f6a6c23629cbf15be84d3de491148941f3` |
| 照合したPR head | `49669a8216fe054a17c48f03b8074023dc03389c` |
| Xcode / SDK | Xcode 26.3 / iOS 26.2 |
| version / build | `1.0.0` / `1` |
| Archive / Export | 両方成功。App Store向けIPAを書き出し済み |
| IPA SHA-256 | `ca74ac9da980cae0521cc2b32db546db24c272ee4512095e1e1f3200fac14345` |
| 検証 | Bundle / Team / version / build、codesign strict、App Storeプロファイル、PrivacyInfo、配布入力24ファイルのSHA一致 |
| 通常起動の接続設定 | IPA実体の `SupabaseURL` / `SupabaseAnonKey` は両方空。公開接続は未検証 |
| App Storeプロファイル期限 | `2027-07-10T11:00:24Z` |

PR headとの差分はUIテストのスクリーンショット取得APIだけです。配布するアプリ・Core・接続設定・アイコン・プロジェクトの入力24ファイルは、Archive sourceとPR headでSHA-256が一致しています。

配布物と `verified-ipa.json`、`runtime-configuration.json`、`provenance.json` はMacの `~/codex-install/travel-map-release-issue3/artifacts/1.0.0-1-8ac2d4f/` に保持しています。署名用の一時Keychainとは別の保存先です。

この検証時点では初回App Store Connect appレコードが未登録のため、アップロードは未実施です。TestFlightへの配布は完了していません。登録後は同じIPAのSHAとApp情報を再照合して `upload` → `status` を進めます。最新の配布状況は [Issue #3](https://github.com/CraftPlusTeam/travel-map/issues/3) に記録します。
