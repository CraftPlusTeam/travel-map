# Travel Map

場所を主語にした、地図が主役の景色発見・旅行記録アプリです。

[元のリポジトリ](https://github.com/yh1110/travel-map) の履歴を保持してCraftPlusTeamへforkし、**SwiftUIのiOS版**を `native/` に追加しています。元のReact Native版は引き続きルートに残しています。ビジョンは [docs/concept.md](docs/concept.md) を参照してください。

## SwiftUI版（iPhone / iPad）

- SwiftUI + MapKit + CoreLocation。iOS 17以降。
- 全画面マップ、写真ピン、100m以内の写真集約、詳細シート、期間別の写真一覧、標準横スワイプ。
- カメラで撮影した景色・撮影場所・日時・タイトルを端末内へ永続保存。
- 公開Supabaseを設定すれば既存の公開マップの閲覧・投稿にも接続。未設定時はサンプル閲覧と端末の記録を利用可能。
- 端末内の記録と公開投稿の保存先を明示。サンプル写真は実際の撮影場所と一致しない体験用データです。

セットアップ・ビルド・テストは [native/README.md](native/README.md)、配布は [native/RELEASE.md](native/RELEASE.md) を参照してください。

```sh
cd native
swift Scripts/generate-icon.swift
xcodegen generate
open TravelMap.xcodeproj
```

## 元のReact Native版

Expo + TypeScript製です。iOSはApple Maps、AndroidはMapLibre + OpenFreeMapを使います。ネイティブモジュールがあるためExpo Goでは動きません。

```sh
npm install
npx supabase start
cp .env.example .env
# npx supabase status のURL・anon keyを.envへ設定
npx expo run:ios
```

実機からローカルSupabaseへ接続する場合は、`.env`のURLをMacのLAN IPにしてMetroを再起動します。`127.0.0.1`は実機自身を指すため使えません。TestFlightでは公開HTTPSのバックエンドが必要です。

最新版 `main` の投稿フローはカメラ → 現在地 → タイトル → 投稿です。初期版の撮影方向入力は廃止済みです。検索やPUBLIC/PRIVATE切替など、一部のUIは未接続のままです。

## Supabase

`supabase/migrations/` と `supabase/seed.sql` を保持しています。

`spots` は `id`、`created_at`、`user_id`、`title`、`lat`、`lng`、`photo_path`、`taken_at` を持ちます。閲覧は公開、投稿は匿名認証ユーザーです。写真は公開 `photos` バケットへ保存します。非公開クラウド投稿のスキーマは未実装です。
