# Travel Map — SwiftUI版

SwiftUI・MapKit・CoreLocationで作ったiOS 17以降のiPhone / iPadアプリです。React NativeのランタイムやMetroは不要です。元のReact Native版とSupabaseのスキーマは保持しています。

## 起動とビルド

MacのXcode 26.3で確認します。XcodeGenが必要です。

```sh
cd native
swift Scripts/generate-icon.swift
xcodegen generate
open TravelMap.xcodeproj
```

Scheme `TravelMap` と実行先を選びます。署名チームの初期値は既存の `BTYVH3R392`、Bundle IDは `com.craftplusteam.travelmap` です。

```sh
# Coreのテスト（Linuxでも実行可能）
swift test

# iOSビルド
xcodebuild -project TravelMap.xcodeproj -scheme TravelMap \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# シミュレータ上の保存処理・UIテスト。利用可能な端末名へ変更してください。
xcodebuild -project TravelMap.xcodeproj -scheme TravelMap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## 機能とデータの保存先

- 「見つける」: 公開バックエンドが設定されていれば投稿を取得します。未設定時はサンプルと明示し、実際の写真・撮影場所ではない体験用データを表示します。
- 「端末の記録」: 撮影写真・撮影地点・日時・タイトルをアプリ内に永続保存します。公開サーバーへ送信せず、自動バックアップの対象からも除外します。アプリの削除で消えるため、大切な写真は別途保管してください。
- 撮影後に位置情報・タイトル・保存先を確認します。公開時は写真と撮影場所が公開されることを確認画面に表示します。位置情報が取得できない場合や拒否された場合は保存せず、理由を表示します。
- 地図上の写真ピンは100m以内を集約し、撮影日時の新しい順に表示します。詳細では今日／今週／すべての絞り込み、写真の標準横ページング、Apple Mapsへの案内・座標共有が使えます。
- 旧版の見た目のみのPRIVATE切替は移植していません。端末の記録は本当に端末内のみです。非公開クラウド投稿、日記、カメラロール自動取込、目的地検索は別タスクです。

## 公開バックエンドへの接続

設定しなくてもサンプル閲覧と端末内への撮影記録を使えます。公開投稿を使う場合のみ、既存Supabaseのホストと公開キーを用意します。リポジトリには本番の接続設定が含まれていません。

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`SUPABASE_URL` と `SUPABASE_ANON_KEY` にHTTPSのホストとpublishable / anonキーを設定してください。`Local.xcconfig` はGit対象外です。URLはxcconfigの `//` コメントと衝突しないよう、例の `https:/$()/...` 形式にします。service_role / sb_secretキーは使用禁止です。公開キーはアプリから抽出可能なため、Supabase側のRLSで保護します。

既存の `supabase/migrations/` を適用したspotsテーブル・photosバケット・匿名認証を利用します。既存サーバーは全公開のスキーマであり、非公開投稿には利用しません。Coreは期限切れセッションのrefreshとKeychain保存、HTTPエラーと不確かな投稿結果を区別します。DB書込失敗時にStorageの削除権限がなければ、画像の手動整理が必要な場合があります。

## 検証上の制約

シミュレータでは地図・詳細・ページング・端末保存ロジックを確認できます。実際のカメラ撮影、GPS精度、権限の設定変更、ネットワーク切断後の再試行はiPhoneでの確認が必要です。TestFlightへアップロードしたことと、実機での撮影確認は区別して記録します。

配布については `RELEASE.md` を参照してください。
