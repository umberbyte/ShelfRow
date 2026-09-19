# ShelfRow マルチデバイス同期 設計書 (Multi-Device Sync Design)

本ドキュメントは、ShelfRow を Mac 複数台および iPad で「意識せずとも各端末が最新の状態になっている」形で使えるようにするための設計を、検討過程・採否理由・データ構造・状態遷移・UI・例外処理まで含めて記録するものである。`documents/design_document.md` の現行仕様を前提とし、変更・追加する箇所だけを扱う。

> 位置づけ: 2026-09-19 設計確定。**Phase 1 実装済み（iCloud 同期はまだ一度もオンにしていない）**、Phase 2・3 未着手。実装で判明した差分は §19 にまとめる。

---

## 0. 確定事項サマリ（意思決定ログ）

ユーザーとの検討で確定した前提と決定。以降の全設計はこれに従う。

| # | 確定事項 | 補足 |
|---|---|---|
| D1 | 利用者は**1人**。複数端末での**同時編集はしない** | マージ層の自作は不要。レコード単位の Last-Writer-Wins で足りる |
| D2 | iPad は**ほぼ閲覧専用**。編集するのは個別ファイルの属性情報（SwiftData 内のフィールド）のみ | iPad から実体ファイルやサムネイルを生成・変更しない |
| D3 | 最優先は**使い心地**。運用の手間を最大限減らし、意識せずに各端末が最新になることを目指す | 手動同期ボタンや「同期してから使う」運用は不可 |
| D4 | **実体ファイルは NAS** に置く | 現行の Volume + 相対パス構造を維持 |
| D5 | **設定情報と SwiftData の内容はクラウド（iCloud）に置いてよい** | 書誌メタデータのみ。著作物は含まれない |
| D6 | **サムネイル等のキャッシュはクラウドへ上げない**。各端末が個別に持つ | 著作物の一部（表紙画像）を Apple のサーバに置かないため。NAS は所有物なので配布元として使ってよい |
| D7 | iCloud 同期の ON/OFF は**環境設定のスイッチ**で切り替える | 未サインイン時はスイッチを ON にできない |
| D8 | スイッチ OFF で**ローカル動作に戻り**、再度 ON で**クラウドに上がる**。何度でも行き来できる | データを失わずに往復できること |
| D9 | iCloud に**サインインしていなければローカルに持つ**（場合分け） | サインアウトでライブラリが消える挙動を許容しない |
| D10 | **どの iCloud アカウントで同期しているか**を設定画面に表示する | ただしメールアドレスは API 上取得不可（§7.3 参照）。取得可能な範囲で表示する |
| D11 | サムネイルは**初回アクセス時に容量警告のうえ一括ダウンロード**、**2回目以降は差分のみ** | 差分検出に NAS のディレクトリ列挙を使わない（§10） |
| D12 | **2台の蔵書を突き合わせるマージは行わない。** 1台目が iCloud へ送り、2台目以降は**ローカルが消える旨を警告したうえで** iCloud の内容に置き換える | 単一利用者・非同時編集（D1）なら、どちらが正かは利用者が知っている。マージ層は作らない |

---

## 1. 目的と要件

### 1.1 目的
- Mac（複数台）と iPad の間で、書誌メタデータ（Item / Shelf / Volume / CoverExtractionRecord）と共有すべき設定を自動同期する。
- 各端末は自分のローカル SwiftData ストアとサムネイルキャッシュを持ち、表示速度は現行の単独 Mac 動作と同等を保つ。
- 実体ファイルは NAS にのみ置く。サムネイルはクラウドに置かない。

### 1.2 機能要件
- FR1 サインイン済み・スイッチ ON のとき、書誌メタデータの変更が他端末へ自動反映される（バックグラウンド、プッシュ通知駆動）。
- FR2 サインインしていない、またはスイッチ OFF のときは現行どおり単独ローカル動作する。
- FR3 スイッチの ON/OFF を何度でも往復できる。反映はアプリの再起動時に行う（§5.4）。
- FR4 Security-Scoped Bookmark は端末固有として同期しない。
- FR5 サムネイルは NAS を配布元として端末ごとに取得・キャッシュする。初回は容量警告つき一括、以降は差分。
- FR6 環境設定に「iCloud」タブを設け、ON/OFF スイッチ、アカウント情報、同期状態、最終同期時刻、エラーを表示する。
- FR7 iCloud サインアウトを検知したら自動的にローカル動作へ落とし、データを保持する。再サインインで自動復帰する。
- FR8 既存ライブラリ（約 19,287 件）を持つ Mac からそのまま移行できる。

### 1.3 非機能要件
- NFR1 軽量性: 既存方針を踏襲。同期のためにメインスレッドをブロックしない。
- NFR2 起動速度: アカウント状態の問い合わせで起動を待たせない（§6.2）。
- NFR3 NAS への負荷: 2万件規模のディレクトリ列挙を行わない。ファイルは名前で直接アクセスする。
- NFR4 データ保全: 同期の ON/OFF・サインイン/アウトのいかなる遷移でもローカルデータを失わない。失う可能性が残る経路にはスナップショットを挟む（§6.6）。
- NFR5 オフライン: NAS に到達できない環境（外出先）でも、同期済みメタデータとローカルキャッシュ済みサムネイルで閲覧・属性編集ができる。

---

## 2. 検討した方式と採否

| 方式 | 概要 | 採否 | 理由 |
|---|---|---|---|
| A. NAS へ DB ファイル丸ごと同期 | 現行バックアップを Push/Pull 化し世代番号で古い上書きを拒否 | 不採用 | 実装は最小だが「使う前に Pull、使った後に Push」の運用が必要で D3 に反する。複数端末で開いたままの状態を扱えない |
| B. NAS 上の追記ジャーナル + スナップショット | 端末ごとの追記ログとフィールド単位 LWW で自作同期 | 不採用 | 同時編集を許容できるが、D1 により不要。マージ層・ポーリング・圧縮処理の自作が重く、変更通知が来ない NAS ではポーリング間隔が「最新性」を制限する |
| C. NAS 上にサーバ（Docker 等） | API + SQLite | 不採用 | インフラ依存が増え「軽量」方針と合わない |
| **D. SwiftData + CloudKit（採用）** | Apple 標準のプライベート DB 同期 | **採用** | プッシュ通知駆動のバックグラウンド同期が標準で付き、同期コード・ポーリング不要。D5 で許容済み。サムネイルは含めない（D6） |

D の副次効果: ローカル DB が「クラウドから再構築できるキャッシュ」になるため、現行の 3 世代スタートアップバックアップで守っている DB 論理破壊への根本対策にもなる。

---

## 3. 全体アーキテクチャ

### 3.1 データの置き場所

| データ | 置き場所 | 仕組み | 同期 |
|---|---|---|---|
| Item / Shelf / Volume / CoverExtractionRecord | iCloud プライベート DB + 各端末ローカルストア | SwiftData `cloudKitDatabase: .private` | 自動 |
| 共有すべき設定（ファイル名解析フォーマット、種類名、項目名、キーワード同一視ルール等） | iCloud KVS + ローカル | `NSUbiquitousKeyValueStore` | 自動 |
| 端末固有の設定（ビューア/ヘルパーのアプリパス、簡易ロック、ウインドウ幅等） | 各端末 | `UserDefaults`（現行どおり） | しない |
| Security-Scoped Bookmark（Volume / Item） | 各端末のローカル専用ストア | SwiftData 第2構成 `cloudKitDatabase: .none` | しない |
| サムネイル | 各端末の Caches + **NAS 上の配布元** | ファイル。差分検出は Item のバージョン番号（§10） | NAS 経由で取得 |
| サムネイル取得状態 | 各端末のローカル専用ストア | `LocalCoverState` | しない |
| 実体ファイル（ZIP / 画像フォルダ等） | NAS | 現行どおり Volume + relativePath | しない |

### 3.2 構成図

```
                         ┌────────────────────────┐
                         │  iCloud (private DB)   │
                         │  Item/Shelf/Volume/    │
                         │  CoverExtractionRecord │
                         │  + KVS(共有設定)        │
                         └───▲────────────▲───────┘
                 CloudKit    │            │    CloudKit
                             │            │
   ┌─────────────────────────┴──┐    ┌────┴──────────────────────────┐
   │ Mac A                      │    │ iPad / Mac B                   │
   │ ┌ Library store (同期)     │    │ ┌ Library store (同期)          │
   │ ├ Local store (非同期)     │    │ ├ Local store (非同期)          │
   │ │  LocalBookmark           │    │ │  LocalBookmark                │
   │ │  LocalCoverState         │    │ │  LocalCoverState              │
   │ └ Caches/Thumbnails        │    │ └ Caches/Thumbnails             │
   └──────┬──────────▲──────────┘    └───────────▲──────┬─────────────┘
          │ 生成→書込 │ 読取                       │ 読取 │ 実体読取
          ▼          │                            │      ▼
   ┌────────────────────────────────────────────────────────────┐
   │ NAS                                                        │
   │  ├ 書籍実体（既存 Volume）                                  │
   │  └ ShelfRowThumbnails/ab/<UUID>.jpg   （配布元、2桁シャード） │
   └────────────────────────────────────────────────────────────┘
```

---

## 4. データモデル変更

### 4.1 CloudKit 連携の制約（SwiftData）
SwiftData を `cloudKitDatabase` 付きで開くには、同期対象スキーマが以下を満たす必要がある。満たさない場合、コンテナ生成時に失敗する。

1. `@Attribute(.unique)` を使わない（CloudKit は一意制約非対応）。
2. リレーションはすべて Optional。
3. 属性は Optional であるか、**宣言側でデフォルト値**を持つ（`init` の既定引数では不十分）。
4. ストア間（同期ストア ⇄ ローカル専用ストア）を跨ぐリレーションは張れない。UUID で参照する。

### 4.2 `Item`（同期側）

| 変更 | 内容 | 理由 |
|---|---|---|
| 削除 | `@Attribute(.unique)` を `id` / `legacyID` から外す | 制約 1 |
| 削除 | `bookmarkData: Data?` | 端末固有。`LocalBookmark` へ移動（§4.5） |
| 追加 | `var coverVersion: Int = 0` | サムネイルの差分検出（§10）。0 = 未生成。生成・再選定・表紙編集のたびに +1 |
| 追加 | `var coverBytes: Int = 0` | NAS 上のサムネイルサイズ。初回一括取得の容量見積もりに使う |
| 変更 | すべての非 Optional プロパティに宣言側デフォルト値を付ける（例: `var title: String = ""`、`var relativePath: String = ""`、`var addedDate: Date = .now`） | 制約 3 |

`legacyID` の一意性は XML インポート時の「fetch してから insert」に置き換える（§4.7）。`coverImageName` / `coverImagePath` は Stackroom 互換フィールドとして残す。

### 4.3 `Volume`（同期側）

| 変更 | 内容 |
|---|---|
| 削除 | `@Attribute(.unique)` |
| 削除 | `bookmarkData: Data?` → `LocalBookmark` へ |
| 変更 | `name` / `lastKnownPath` に宣言側デフォルト値 |

`lastKnownPath` は「最後に解決できたパス」の参考情報として同期してよい（端末ごとにマウントポイントが違っても害はなく、ボリューム管理画面のヒントになる）。

### 4.4 `Shelf`（同期側）
| 変更 | 内容 |
|---|---|
| 削除 | `@Attribute(.unique)` |
| 変更 | 非 Optional プロパティに宣言側デフォルト値 |

`smartConditionsJson` は文字列のため CloudKit 互換に問題なし。

### 4.5 `LocalBookmark`（ローカル専用・新規）

```swift
@Model
final class LocalBookmark {
    var targetID: UUID = UUID()     // Item.id または Volume.id
    var kind: Int = 0               // 0 = volume, 1 = item
    var data: Data = Data()
    var updatedAt: Date = .now
}
```

- `ItemFileAccess` の解決順は現行どおり「Item 個別ブックマーク → Volume ブックマーク」。参照先を `Item.bookmarkData` から `LocalBookmark` の検索に置き換える。
- 検索コストを避けるため、起動時に `[UUID: Data]` の辞書をメモリに載せ、更新時に書き戻す。
- **同期させてはならない理由**: 端末 A のブックマークが B に届く → B で解決失敗 → B で選び直す → B の値が A に届いて A のブックマークを潰す、というピンポンが起きるため。

### 4.6 `LocalCoverState`（ローカル専用・新規）

```swift
@Model
final class LocalCoverState {
    var itemID: UUID = UUID()
    var version: Int = 0            // ローカルキャッシュにあるサムネイルのバージョン
    var pendingUpload: Bool = false // Mac が生成したが NAS へ未送信
    var lastError: String? = nil
    var updatedAt: Date = .now
}
```

用途は §10。

### 4.7 `CoverExtractionRecord`（同期側・既存）
「表紙抽出を試みたが使える表紙が無かった」という判定は端末に依らない共有知識なので同期側に置く。制約 1〜3 を満たすよう `.unique` 撤廃とデフォルト値付与のみ行う。

### 4.8 `LibraryImporter` の重複排除
- `legacyID` の一意制約が無くなるため、XML インポートでは `FetchDescriptor<Item>(predicate: #Predicate { $0.legacyID == id })` で既存を引き当ててから作成/更新する。
- 大量件数のため、インポート開始時に既存 `legacyID → PersistentIdentifier` の辞書を一度作り、以降は辞書で判定する（19,287 件で数十 ms）。

### 4.9 既存ストアからのマイグレーション
- 制約対応（`.unique` 撤廃、デフォルト値付与、`bookmarkData` 削除、`coverVersion` / `coverBytes` 追加）は SwiftData の軽量マイグレーションで通る見込み。`bookmarkData` は**削除前に** `LocalBookmark` へ移す必要があるため、以下の順で行う。
  1. 旧スキーマ（`bookmarkData` あり）で開き、全 Item / Volume の `bookmarkData` を `LocalBookmark` にコピー。
  2. 新スキーマで開く。
- 実装上は `VersionedSchema` + `SchemaMigrationPlan` のカスタム段階として記述する。
- 既存サムネイルキャッシュ（`Caches/<bundle>/Thumbnails/<UUID>.jpg`）は削除せず、§10.9 の「NAS へ一括登録」で `coverVersion = 1` を付与する。

---

## 5. ストア構成と `LibraryStore`

### 5.1 2 つの `ModelConfiguration`

```swift
let librarySchema = Schema([Item.self, Shelf.self, Volume.self, CoverExtractionRecord.self])
let localSchema   = Schema([LocalBookmark.self, LocalCoverState.self])

let library = ModelConfiguration(
    "Library",
    schema: librarySchema,
    url: applicationSupport.appendingPathComponent("default.store"),   // 既存ファイルを継続使用
    cloudKitDatabase: mode == .cloud ? .private("iCloud.com.eureka.ShelfRow") : .none
)
let local = ModelConfiguration(
    "Local",
    schema: localSchema,
    url: applicationSupport.appendingPathComponent("local.store"),
    cloudKitDatabase: .none
)
let container = try ModelContainer(for: Schema(librarySchema, localSchema), configurations: [library, local])
```

- **同期ストアのファイルは 1 つ**（`default.store`）。cloud / local の違いは開き方だけ。CloudKit のレコード対応表（`ANSCKRECORDMETADATA` 等）と永続履歴は同じ SQLite に残るため、OFF→ON で再アップロード全件にならず**差分から再開**できる。これが FR3 / D8 を成立させる要。
- `local.store` は同期しない。バックアップ対象（§12）。

### 5.2 `LibraryStore`（新規、`@Observable`、`@MainActor`）

```swift
@Observable @MainActor
final class LibraryStore {
    enum Mode { case local, cloud }
    private(set) var mode: Mode
    private(set) var container: ModelContainer
    private(set) var generation: Int = 0      // 切替のたびに +1。ルートビューの .id に使う
    var isSwitching = false
    var blockingTask: String?                  // 実行中の長時間タスク名（切替を禁止する理由）

    func switchMode(to: Mode) async throws
}
```

- `ShelfRowApp.sharedModelContainer`（現在は固定構成で即時生成）を `LibraryStore` に置き換える。
- ルートビューは `.modelContainer(store.container).id(store.generation)`。`generation` が変わるとビュー階層が丸ごと再生成され、旧コンテナへの参照（`@Query`, `@Environment(\.modelContext)`）がすべて解放される。
- `@ModelActor` である `LibraryImporter` と表紙抽出アクターは、コンテナを引数に生成しているため、切替後に**新コンテナから作り直す**。`LibraryStore` がファクトリを提供する。
- 起動時 3 世代バックアップ（`SwiftDataStartupBackup`）は従来どおり「コンテナ生成の直前」に実行する。切替時は実行しない（§6.6 のスナップショットが代替）。

### 5.3 切替手順（`switchMode`）
1. `blockingTask != nil`（インポート / 一括サムネイル生成 / NAS 一括登録 / リストア中）なら拒否し、UI にその旨を表示。
2. `isSwitching = true`。進行中の Prefetch（`ThumbnailCache`）をキャンセル。
3. cloud へ切り替える場合のみ、§6.6 のローカルスナップショットを取得。
4. 新モードで新 `ModelContainer` を生成（失敗したら旧コンテナを維持して `isSwitching = false`、エラー表示）。
5. `container` を差し替え、`generation += 1`、`mode` を更新、`UserDefaults["libraryMode"]` に保存。
6. 旧コンテナの参照を手放す。旧コンテナは全ビュー・アクターの参照が消えた時点で解放され、SQLite 接続が閉じる。
7. cloud に切り替えた場合は §9 の「両側非空」判定を行う。
8. `isSwitching = false`。

### 5.4 モード変更は再起動で反映する（ホットスワップは失敗した）

当初は実行中にコンテナを差し替える方針だったが、**実装して動かした結果クラッシュしたため取りやめた**。

```
SwiftData/BackingData.swift:888: Fatal error: This model instance was destroyed by
calling ModelContext.reset and is no longer usable. ... Item/p2220
frame 7: Item.id.getter
```

`container` を差し替えると古い `ModelContext` が reset され、そこに属する `Item` は以後触れた瞬間にトラップする。ルートビューに `.id(generation)` を付けて木を作り直しても足りない: SwiftUI は同じ更新の中で古いビューの body をもう一度評価することがあり、プリフェッチやページ数更新など実行中の `Task` も古いモデルを捕まえたままでいる。全参照が確実に消えている瞬間は、**最初のコンテナができる前**しかない。

したがってモード変更は次の形をとる。

1. 設定（`iCloudSyncEnabled` と `libraryLastEffectiveMode`）を書く
2. `NSWorkspace.openApplication` + `NSApp.terminate` で自動再起動
3. `LibraryStore.init()` が保存された設定を読んで、最初から正しいモードで開く

§9 の「iCloud の蔵書で置き換える」がストアファイルの削除に再起動を要求するのと同じ理由であり、機構も共有している。

**アカウント状態の変化（サインイン/アウト）では自動再起動しない。** 勝手にアプリが落ちて立ち上がるのは乱暴なので、`restartRequired` を立てて設定画面に「再起動すると新しい設定で開きます」と [今すぐ再起動] を出すに留める。次回起動時には自動的に正しいモードになる。

## 6. 動作モードの決定と遷移

### 6.1 モード決定式

```
実効モード = (設定「iCloud同期」== ON) && (accountStatus == .available) ? cloud : local
```

設定値（ユーザーの意思）と実効モード（実際の開き方）は別物として持つ。サインアウト中は「設定 ON・実効 local」になり、再サインインで自動的に「設定 ON・実効 cloud」へ戻る（FR7）。

### 6.2 起動シーケンス

```
1. UserDefaults から前回の実効モードを読む（初回は local）
2. そのモードで即座に ModelContainer を生成し UI を表示   ← accountStatus を待たない
3. 裏で CKContainer.accountStatus() を取得（タイムアウト 5 秒）
4. 決定式で求めた実効モードが手順 1 と異なる場合:
     - 自動切替が安全なら（長時間タスクなし）: switchMode を実行し、バナー「iCloud 同期を開始/停止しました」
     - 安全でなければ: バナー「iCloud の状態が変わりました [今すぐ切替]」
5. CKAccountChanged / NSPersistentCloudKitContainer.eventChangedNotification の監視を開始
```

`accountStatus()` は通常 100 ms 以内だが、iCloud デーモンの状態によっては数秒待たされることがあるため、手順 2 で起動を止めない。

### 6.3 状態遷移表

| 現在 | イベント | 次の実効モード | データへの影響 | UI |
|---|---|---|---|---|
| local | スイッチ ON（サインイン済み） | cloud | 既存レコードが初回エクスポートでクラウドへ | 進捗と「両側非空」判定（§9） |
| local | スイッチ ON（未サインイン） | local | なし | スイッチは操作不可。理由「iCloud にサインインしていません」を表示 |
| cloud | スイッチ OFF | local | なし（未送信の変更はローカルに残り、次回 ON で送られる） | 状態欄「ローカルで動作中」 |
| cloud | サインアウト検知（CKAccountChanged → noAccount） | local | なし（§6.6 の残余リスクあり） | 状態欄「未サインインのためローカルで動作中」 |
| local（設定 ON） | サインイン検知（同一アカウント） | cloud | ストアに記録された前回ユーザー ID と一致 → 差分同期から再開 | バナー「iCloud 同期を再開しました」 |
| local（設定 ON） | サインイン検知（**別アカウント**） | cloud | フレームワークがローカルの同期データを破棄して新アカウントから取り直す | **切替前に確認ダイアログ**「別の iCloud アカウントです。ローカルのライブラリは新しいアカウントの内容に置き換わります」。拒否なら設定を OFF にする |
| 任意 | 長時間タスク実行中に上記いずれか | 変更なし | なし | スイッチ無効化、「完了後に切り替えてください」 |

### 6.4 サインアウト時にデータが消えない理由
CloudKit 連携ストア（`NSPersistentCloudKitContainer`）は、**アカウントが変わった／無くなったと検知すると同期済みローカルデータを削除**する（別ユーザーのデータを見せないための仕様）。本設計では未サインイン時に**そもそも CloudKit 付きでコンテナを開かない**ため、この削除経路に入らない。再サインイン時はストアに記録されたユーザーレコード ID と照合され、同一なら差分同期、別人なら §6.3 の確認を経て置き換えとなる。

### 6.5 フォールバック: 再起動方式
ホットスワップ（§5.3）が安定しない場合、切替を「次回起動時に反映」とし、バナーに [今すぐ再起動] を置く。
- macOS: `NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: { createsNewApplicationInstance = true })` を呼んでから `NSApp.terminate(nil)`。サンドボックス内で可能。
- iPadOS: アプリは自身を再起動できないため「アプリを終了して開き直してください」の案内のみ。

### 6.6 残余リスクとスナップショット
- 同一セッション中のサインアウトでは、`CKAccountChanged` を受けてローカル構成へ切り替えるより先に、フレームワーク側の削除処理が走る可能性がゼロではない。
- 対策: **cloud モードへ切り替える直前に必ずローカルスナップショット**を取る。`SwiftDataStartupBackup` のコピー処理を流用し、`Application Support/ModeSwitchBackups/` に 1 世代保存（`default.store*` + `local.store*`）。
- 起動時 3 世代バックアップと環境設定 > 保守の NAS バックアップもそのまま残す。
- 万一消えた場合の復旧: 再サインインでクラウドから戻る／スナップショットから手動復元（`update_history.md` 第 8 期の手順に準ずる）。

---

## 7. iCloud アカウント監視

### 7.1 取得する情報
| 情報 | API | 備考 |
|---|---|---|
| アカウント状態 | `CKContainer.default().accountStatus()` | `.available` / `.noAccount` / `.restricted` / `.temporarilyUnavailable` / `.couldNotDetermine` |
| 状態変化 | `NSNotification.Name.CKAccountChanged` | サインイン/アウト、アカウント切替 |
| ユーザーレコード ID | `CKContainer.default().userRecordID()` | 不透明な ID（例 `_3f9a12…`）。**同一アカウントなら全端末で同じ値** |
| 同期イベント | `NSPersistentCloudKitContainer.eventChangedNotification` | SwiftData 経由でも通知は届く。`type`（setup / import / export）、`startDate` / `endDate`、`succeeded`、`error` |
| 「このアプリの iCloud」がオフ | 同期イベントの `error`（`CKError.notAuthenticated` 等） | `accountStatus` では判別不能。イベントエラーから状態欄に反映 |

### 7.2 状態欄の表示マッピング

| 内部状態 | 表示 | スイッチ |
|---|---|---|
| available かつ直近イベント成功 | 「同期中（最終同期: 今日 14:02）」 | 有効 |
| available かつ直近イベント失敗 | 「エラー: <要約>」+ 詳細展開 | 有効 |
| noAccount | 「iCloud にサインインしていません。ローカルで動作中」 | 無効 |
| restricted | 「iCloud の利用が制限されています（スクリーンタイム/構成プロファイル）」 | 無効 |
| temporarilyUnavailable / couldNotDetermine | 「iCloud の状態を確認中…」（再試行あり） | 一時無効 |
| available だがアプリの iCloud がオフ | 「システム設定で ShelfRow の iCloud がオフになっています」+ [システム設定を開く] | 有効（ON にしてもエラー表示のまま） |
| 容量不足（`CKError.quotaExceeded`） | 「iCloud の空き容量が不足しています」 | 有効 |

### 7.3 「どのアカウントか」の表示範囲
CloudKit はプライバシー保護のため、サインイン中の Apple ID の**メールアドレス・氏名をアプリに渡さない**。以前存在した `discoverUserIdentity` / `userDiscoverability` 系 API は macOS 14 / iOS 17 で廃止済み。`FileManager.ubiquityIdentityToken` も不透明トークンである。
したがって設定画面には以下を表示する。
- ユーザーレコード ID（先頭 10 文字程度に省略、クリックで全体コピー）。「同じ iCloud アカウントの端末では同じ ID になります」と注記。
- [システム設定でアカウントを確認] ボタン: macOS は `x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane`、iPadOS は `App-prefs:` 系 URL（利用可否は OS バージョン依存のため、失敗時は「設定 > Apple ID を開いてください」と案内）。

### 7.4 初期インポート完了の検知
サムネイルの初回一括取得（§10.5）は**初期インポート完了後**に開始する。`eventChangedNotification` で `type == .import` かつ `endDate != nil` かつ `succeeded == true` のイベントを「1 回以上」観測したことを条件とする。これを待たずに件数を数えると、同期途中の少ない件数で誤った容量警告を出してしまう。

---

## 8. 環境設定「iCloud」タブ

### 8.1 レイアウト（サイドバー式設定ウインドウに「iCloud」を追加。位置は「セキュリティ」の前）

```
iCloud

[✓] iCloud 同期                                      ← スイッチ（§8.2）
    書誌情報（本・シェルフ・ボリューム）と共有設定を iCloud で同期します。
    サムネイルや書籍ファイルは iCloud に送信されません。

状態         同期中（最終同期: 今日 14:02）
アカウント   _3f9a12…（同じ iCloud アカウントの端末では同じ ID になります） [コピー] [システム設定で確認]
現在のモード クラウド                                  ← 設定 ON でもサインアウト中は「ローカル（未サインイン）」

[今すぐ同期]  [クラウドから取り直す…]                  ← §8.3
直近のエラー  （なし）
```

### 8.2 スイッチの振る舞い
- ON 操作: `accountStatus` を再取得 → `.available` でなければ元に戻して理由を表示 → §5.3 の切替 → §9 の判定。
- OFF 操作: 確認ダイアログなしで切替（データは残るため）。ただし直近エクスポート未完了の変更がある場合は「送信していない変更があります。次に ON にしたとき送信されます」と注記。
- 長時間タスク中は無効化（§5.3 手順 1）。

### 8.3 補助操作
- **今すぐ同期**: `eventChangedNotification` のトリガにはならないため、実体は「軽い書き込み（ダミー更新は行わない）」ではなく、`CKContainer` の到達性確認と状態欄の再取得に留める。SwiftData/CloudKit は自動でスケジュールするため、ボタンは主に「状態を確認したい」需要に応える。
- **クラウドから取り直す…**: ローカルの同期ストアを破棄してクラウドから全件取り直す。確認ダイアログ必須。ローカル専用ストア（ブックマーク・取得状態）とサムネイルは保持する。手順: スナップショット → `default.store*` 削除 → cloud モードで再生成 → 初期インポート待ち。

### 8.4 一般タブへの影響
- 設定の同期範囲（§11）に従い、共有設定の項目には小さく「iCloud で同期」のバッジを付ける。

---

## 9. 有効化時にどちらの蔵書を残すか

**マージはしない（D12）。** 2台の蔵書を突き合わせる処理は、単一利用者・非同時編集という前提では割に合わず、失敗したときの被害が大きい。代わりに、同期を有効化する操作そのものを「どちらの蔵書を残すか」の選択にする。

### 9.1 選択肢

設定の「iCloud同期」スイッチをオンにすると確認ダイアログが出る。

| 選択 | 動作 | 想定 |
|---|---|---|
| この端末の蔵書を iCloud へ送る | そのまま cloud モードで開き直す。ローカルの内容が iCloud を満たす | 1台目 |
| iCloud の蔵書で置き換える（破壊的） | この端末の `default.store` と `local.store` を削除し、空の状態で cloud モードに接続する。iCloud から全件が降りてくる | 2台目以降 |
| キャンセル | 何もしない。スイッチはオフのまま | |

すでに iCloud に蔵書がある状態で「1台目」を選ぶと同じ本が二重に登録される。これはダイアログ本文で明示する。自動判別（iCloud 側が空かどうかの問い合わせ）は行わない: 単一利用者はどちらの端末かを知っており、判別のために CloudKit のスキーマへ専用レコードを足すほうが構成を複雑にする。

### 9.2 「置き換え」を削除ではなくファイル削除で行う理由

cloud モードのまま `modelContext.delete` でローカルのレコードを消すと、**その削除が iCloud へ伝播して全端末の蔵書が消える**。置き換えはレコード操作ではなく、ストアファイルごと捨ててから空の状態で接続する形でなければならない。

### 9.3 再起動を挟む理由

ストアファイルの削除は、それを開いているコンテナが存在しない瞬間にしか安全に行えない。アプリ実行中は必ずどちらかのモードでコンテナが開いているため、**削除予約フラグ（`libraryPendingResetFromCloud`）を立てて再起動**し、`LibraryStore.init()` が最初のコンテナを作る前に実行する。macOS では `NSWorkspace.openApplication` + `NSApp.terminate` で自動的に再起動する。

直前に `ModeSwitchBackups/` へスナップショットを取るので、誤操作しても手動で戻せる。

### 9.5 iCloud のデータを完全に削除する

アプリの利用をやめるとき、iCloud の容量を解放できるようにする。環境設定 > iCloud の「iCloudから完全に削除...」。

| 対象 | 扱い |
|---|---|
| iCloud 上の書誌情報 | **削除される。** コンテナのプライベートDBにある既定ゾーン以外のゾーンをすべて削除する（コンテナはこのアプリ専用なので、そこにあるものは全部自分のもの） |
| この端末の蔵書・サムネイル・設定 | **残る** |
| iCloud 同期の設定 | オフになる |

**ミラーリング中に削除してはならない。** cloud モードのままゾーンを消すと、CloudKit はゾーンが消えたことを検知してライブラリ全体を再アップロードする。したがって §9.3 と同じ仕組みで、削除予約フラグ（`libraryPendingCloudPurge`）を立てて同期をオフにし、**再起動後・ローカルモードで開いた状態で** `CloudAccountMonitor.purgeCloudStorage()` を実行する。

**他端末への注意:** 他の端末で同期がオンのままだと、その端末が同じ内容を再びアップロードする。確認ダイアログに「先にすべての端末で同期をオフにしてください」と明記する。

### 9.4 置き換え後に失われるもの

| | 扱い |
|---|---|
| 蔵書・シェルフ・ボリューム | iCloud の内容に置き換わる |
| Security-Scoped Bookmark | **削除される。** ボリュームのアクセス権を再設定する必要がある（`local.store` も消すため。iCloud 側の Volume は別の UUID を持つので、残しても対応づかない） |
| サムネイルキャッシュ | **残る**（Caches 配下、ストアファイルではない）。ただし Item の UUID が変わるため、Phase 2 で NAS から取り直すことになる |
| 端末固有の設定 | 残る（`UserDefaults`） |

同期が終わるまで蔵書は空に見える。ダイアログ本文でその旨を伝える。

## 10. サムネイル配布と差分同期

### 10.1 方針
- 生成は Mac のみ（D2）。生成した Mac がローカルキャッシュと **NAS 配布元**の両方に書く。
- 他端末（iPad / 別 Mac）は NAS から取得してローカルキャッシュに置く。iPad に SMB 越しの ZIP 展開はさせない。
- 差分検出には NAS のディレクトリ列挙を使わない（NFR3）。**CloudKit で同期される `Item.coverVersion` を差分インデックスとして使う**。

### 10.2 NAS レイアウト

```
<ユーザーが選んだ NAS フォルダ>/ShelfRowThumbnails/
  ab/<UUID>.jpg        ← UUID 先頭 2 桁（16 進）でシャーディング。1 階層 2 万ファイルの列挙・作成コストを避ける
  .shelfrow            ← 配布元であることの目印（内容: フォーマットバージョン）
```

- 書き込みは「同一ディレクトリに一時ファイルを書き、`rename`」で行う（SMB でも同一ディレクトリ内 rename はほぼ原子的）。
- 配布元フォルダは環境設定 > 保守（または iCloud タブ）で選択し、Security-Scoped Bookmark を `LocalBookmark`（kind = 2: thumbnailRoot）に保存する。端末ごとに選び直す（NAS のマウント方法が端末で違うため）。
- iPad では「ファイル」アプリで接続した SMB 共有内のフォルダを `UIDocumentPickerViewController` で選ぶ。

### 10.3 差分検出式

```
ローカル取得状態: LocalCoverState[itemID].version（無ければ 0）
取得対象集合    = { item | item.coverVersion > localVersion(item.id) }
```

- 初回（全件 `localVersion = 0`）も 2 回目以降も同じ式で求まる。
- Mac が表紙を再選定すると `coverVersion` が +1 され、CloudKit のプッシュで他端末へ届き、その 1 件だけが対象になる。
- 状態を持たず毎回再計算するため、中断・再開・端末追加・キャッシュ削除のいずれにも同じコードで対応できる。

### 10.4 対象集合の計算コスト
- 19,287 件の `coverVersion` / `coverBytes` / `id` を `FetchDescriptor` で `propertiesToFetch` 限定で取得し、`LocalCoverState` を辞書化して突き合わせる。数十 ms〜百 ms 程度。バックグラウンド `ModelActor` で行う。

### 10.5 初回フロー（端末ごと）

```
前提: 実効モード cloud、初期インポート完了（§7.4）、配布元フォルダ選択済み、NAS 到達可
1. 対象集合を計算 → 件数 N、合計 Σ coverBytes = X
2. N >= 500 または X >= 50 MB（初期値。実測後に調整）なら警告シート:
     「N 件・約 X MB のサムネイルを NAS から取得します」
     空き容量: 取得先ボリュームの空きが X × 1.2 未満なら赤字で警告
     iPad: NWPathMonitor.isExpensive（従量課金回線）なら追加警告
     [今すぐ取得]  [後で]  [閲覧に応じて取得のみ]
3. [今すぐ取得] → 一括取得エンジン開始（§10.6）
   [後で]      → 次回起動時に再提示
   [閲覧に応じて取得のみ] → 一括はせず、CoverPrefetchWindow の範囲だけ取得。設定タブから後で一括に切替可
4. 取得中も閲覧可。進捗はサイドバー下部のバナー（「サムネイル取得中 3,210 / 19,287」）と保守タブに表示
```

### 10.6 一括取得エンジン
- `TaskGroup` で並列 8（SMB はレイテンシ律速のため、小ファイルは並列が効く。iPad の Wi-Fi でも 8 程度が妥当。設定で 4〜16 に変更可）。
- 1 件ごとの処理: NAS から読み取り → ローカル Caches に一時名で書き → rename → `LocalCoverState.version = item.coverVersion` を保存。
- 優先度: `ThumbnailCache` の `CoverPrefetchWindow`（カーソル周辺 ±25 行）からの要求を**一括キューより優先**する。実装は「一括キュー」と「表示キュー」を分け、表示キューが空のときだけ一括キューから取り出す。
- 失敗（NAS 未到達、ファイル無し）は `LocalCoverState.lastError` に記録して次へ進む。ファイル無しは「Mac 側がアップロード保留中」の可能性があるので、次回の対象集合計算で再試行される。
- アプリ終了で中断しても、次回は残りだけが対象になる。
- 取得済みの検証は行わない（サイズ照合のみ。ハッシュは計算しない）。

### 10.7 2 回目以降
- トリガ: 起動時、フォアグラウンド復帰時、CloudKit の import イベント完了時、配布元フォルダが到達可能になった時。
- 対象集合が閾値未満なら**警告なしで静かに取得**。閾値以上（Mac で大量再生成した直後など）なら §10.5 の警告を出す。

### 10.8 生成側（Mac）の振る舞い
1. 表紙生成 / 再選定 / 表紙編集 → ローカル Caches に保存 → NAS へ書き込み → `Item.coverVersion += 1`, `Item.coverBytes = サイズ` を保存。
2. NAS に到達できない場合: ローカル保存と `coverVersion += 1` は行い、`LocalCoverState.pendingUpload = true` で保留。配布元が到達可能になった時点でまとめて送る（出先で表紙を直しても帰宅後に自動反映）。
3. 他端末が `coverVersion` だけ先に受け取り NAS に無い場合は §10.6 の「ファイル無し」扱いで次回再試行される。
4. 別の Mac は `coverVersion > 0` の本を**自分で生成しない**。NAS から取得する。生成が必要なのは `coverVersion == 0` かつ `CoverExtractionRecord` が「未試行」の本だけ。
5. 一括サムネイル生成（保守タブ）は、この規則により「未生成の本だけ」を対象にする現行仕様と自然に整合する。

### 10.9 既存キャッシュの NAS への一括登録（移行時に 1 回）
- 保守タブに「サムネイルを NAS 配布元へ登録…」を追加。既存ローカルキャッシュ（約 19,000 件）を NAS へコピーし、各 Item に `coverVersion = 1`, `coverBytes` を設定する。
- 並列 8、進捗表示、中断再開可（`coverVersion == 0` かつローカルにファイルがあるものが残り）。
- 完了後に他端末で §10.5 の初回フローが成立する。

### 10.10 掃除
- ローカル: Item が削除されたら、ローカル Caches のディレクトリ列挙（ローカルなので速い）で Item ID に無いファイルと `LocalCoverState` を削除。起動時に低優先度で実行。
- NAS: Mac の保守タブ「NAS サムネイルの整理」で同様に処理。iPad からは行わない。

### 10.11 容量の見積もり
- 実測値は未取得（サンドボックスコンテナのため計測はユーザーのターミナルで実行する必要がある）。目安として 1 枚 30〜50 KB × 19,287 件 = **約 0.6〜1 GB**。
- 初回のみ Wi-Fi 推奨。以降の差分は通常数 MB 以下。
- 実測後に閾値（500 件 / 50 MB）と警告文の数値を調整する。

---

## 11. 設定の分類（同期する／しない）

| 設定 | 保存先 | 同期 | 理由 |
|---|---|---|---|
| ファイル名解析フォーマット | KVS | する | ライブラリの意味論に属する |
| 種類名・項目名のカスタマイズ | KVS | する | 同上 |
| キーワード同一視ルール（`keywordEquivalenceRulesJson`） | KVS | する | 同上 |
| iCloud 同期スイッチ（ユーザーの意思） | UserDefaults | しない | 端末ごとに ON/OFF したい場合がある |
| 実効モード（前回） | UserDefaults | しない | 起動高速化用のキャッシュ |
| ビューア / ヘルパーのアプリパス | UserDefaults | しない | Mac のアプリパスは iPad に意味がない |
| 簡易ロック | UserDefaults | しない | 端末ごと |
| ウインドウ・ペイン幅、表示モード、ソート | UserDefaults | しない | 端末ごと |
| バックアップ先ブックマーク | LocalBookmark | しない | 端末固有 |
| サムネイル配布元ブックマーク | LocalBookmark | しない | 端末固有 |

- `NSUbiquitousKeyValueStore` は 1 MB / 1024 キーの上限があるが、対象は小さな JSON のみで十分に収まる。
- KVS の変更通知（`NSUbiquitousKeyValueStore.didChangeExternallyNotification`）を受けて `UserDefaults` 側へミラーし、既存の `@AppStorage` 読み出しを変えずに済ませる。書き込みは両方へ行う。

---

## 12. バックアップとの関係

| 既存機能 | 変更 |
|---|---|
| 起動時 3 世代バックアップ | 維持。`local.store*` も対象に加える |
| 環境設定 > 保守 > バックアップ（NAS） | 維持。`local.store*` を対象に追加。Thumbnails は §10.2 の配布元が実質的なバックアップになるため、**配布元登録済みなら省略可**のチェックを追加 |
| リストア | 維持。cloud モード中のリストアは「クラウドと矛盾する」ため、リストア前に自動で local へ切り替え、完了後は「クラウドを正にするか、ローカルを正にするか」を §9 と同じダイアログで確認する |
| モード切替スナップショット（新規、§6.6） | `Application Support/ModeSwitchBackups/` に 1 世代 |

---

## 13. iPad（Phase 3）の論点

同期方式とは独立に決める必要がある項目。

| 論点 | 選択肢 | 現時点の方針 |
|---|---|---|
| プラットフォーム分離 | `ContentView` / `ShelfRowApp` の AppKit 依存（`NSEvent` 修飾キー判定、`NSWorkspace`、`NSOpenPanel`、Settings シーン等、計 28 箇所）を抽象化してマルチプラットフォームターゲット化 | 実施。リスト/グリッドのクリック・キーボード操作は iPad 向けに作り直しに近い |
| NAS アクセス | 「ファイル」アプリで SMB 接続 → `UIDocumentPickerViewController` でフォルダ選択 → Security-Scoped Bookmark | 実施。「ボリューム管理」画面を流用 |
| 書籍本文の閲覧 | (a) 共有シート / `UIDocumentInteractionController` で外部リーダーへ渡す (b) 簡易ビューア内蔵 | **未決**。README 方針（ビューア非内蔵）を守るなら (a)。D2「ほぼ閲覧専用」がカタログ閲覧を指すなら本文閲覧は当面対象外 |
| オフライン | 同期済みメタデータ + ローカルキャッシュ済みサムネイルで閲覧・属性編集可。NAS 未到達時は実体アクセス系の操作を無効化 | 実施 |
| バックグラウンド同期 | `Background Modes: Remote notifications` を有効化し、CloudKit のサイレントプッシュで取り込む | 実施 |

---

## 14. 署名・エンタイトルメント・配布

### 14.1 追加するエンタイトルメント（`ShelfRow.entitlements`）
| キー | 値 | 用途 |
|---|---|---|
| `com.apple.developer.icloud-services` | `CloudKit` | SwiftData 同期 |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.com.eureka.ShelfRow` | コンテナ |
| `com.apple.developer.ubiquity-kvstore-identifier` | `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` | KVS |
| `com.apple.developer.aps-environment` | `production` | サイレントプッシュ（これが無いと変更通知が届かず、取り込みが起動時・定期のみになる） |
| （iPad）`UIBackgroundModes` | `remote-notification` | バックグラウンド取り込み |

> **キー名の注意:** プッシュのエンタイトルメントは macOS では `com.apple.developer.aps-environment`。iOS の `aps-environment` を書いてもプロビジョニングプロファイルが付与しないため、署名時に無言で削除される。値は開発署名で `development`、Developer ID / App Store で `production` である必要があるので、ビルド設定 `APS_ENVIRONMENT` を Debug/Release で切り替えて `$(APS_ENVIRONMENT)` として参照する。

### 14.2 Developer ID 配布との関係
- CloudKit は Developer ID 署名（App Store 外配布）でも利用できるが、**iCloud エンタイトルメント入りの Developer ID プロビジョニングプロファイル**が必要になる。自動署名（`signingStyle: automatic`）で `-allowProvisioningUpdates` を付けた現行のリリース手順（v1.1 で確立）が引き続き使える見込みだが、**Phase 1 の最初に Archive → Export → 公証まで通して確認する**。
- 公証（notarytool）とステープルの手順は変更なし。

### 14.3 CloudKit Dashboard
- 開発中は Development 環境にスキーマが自動生成される。**リリース前に Production へスキーマをデプロイ**する（Dashboard 操作）。忘れると本番ビルドで同期が失敗する。
- スキーマ変更（フィールド追加）は追加のみ可能で削除不可。`coverVersion` / `coverBytes` は最初から入れておく。

---

## 15. 例外・エラー処理マトリクス

| 事象 | 検知 | 挙動 | ユーザー表示 |
|---|---|---|---|
| 未サインインでスイッチ ON | `accountStatus != .available` | 切替しない | スイッチ横に理由 |
| アプリの iCloud がシステム設定でオフ | export/import イベントの `CKError.notAuthenticated` | cloud モード維持（ローカル書き込みは継続） | 状態欄 + [システム設定を開く] |
| iCloud 容量不足 | `CKError.quotaExceeded` | 同上 | 状態欄 |
| ネットワーク不通 | `CKError.networkUnavailable` / `.networkFailure` | 同上（自動再試行はフレームワーク任せ） | 状態欄「オフライン」 |
| レート制限（`requestRateLimited` / `zoneBusy` / `serviceUnavailable`） | 同期イベントのエラー | **失敗として扱わない。** フレームワークが待って自動再開する | 「同期の進行」欄に待機中と表示。警告は出さない |

> **初回シードでは常態:** 19,287 件を送ると `CKErrorDomain Code=7`（`requestRateLimited`）が数秒おきに出る。`CKRetryAfter` が付かないこともあるため、キーの有無だけでなくエラーコードでも一時的と判定し、`NSUnderlyingError` の連鎖も辿る。
>
> **進捗率・件数は表示しない（方針変更）:** 一度は非公開テーブル `ANSCKRECORDMETADATA` を読んで百分率を出したが、実用上ほぼ常に 100% を指すだけで意味を持たなかったため撤去した。`NSPersistentCloudKitContainer.Event` が公開するのは開始/終了時刻・成否・エラーだけで、残りの件数を知る公開手段は無い。
>
> 表示するのは**同期中かどうか**だけにする。イベントが届いている間は回転アイコン、最後のイベントから 90 秒途切れたら「送受信完了」。件数・回数・経過時間・百分率はいずれも出さない。

> **テスト実行時は実ライブラリを開かない:** このスキームはアプリ自身をテストホストにするため、テストのたびにアプリが起動して実ストアを開き、同期が有効なら CloudKit にも接続してしまう。テストが作る別コンテナと衝突してテストホストが落ちるうえ、利用者のデータを無用に開くことになる。`LibraryStore.init()` は `XCTestConfigurationFilePath` を見て、テスト実行時はインメモリのストアで起動する。
| サインアウト | `CKAccountChanged` → `.noAccount` | local へ自動切替（§6.3） | バナー |
| 別アカウントでサインイン | `userRecordID` 不一致 | 確認ダイアログ後に切替 or 設定 OFF | ダイアログ |
| 切替中のコンテナ生成失敗 | `ModelContainer` 初期化 throw | 旧コンテナ維持 | エラー表示、設定値は元に戻す |
| 長時間タスク中の切替要求 | `blockingTask != nil` | 拒否 | 「完了後に切り替えてください」 |
| 有効化時にどちらを残すか | スイッチのオン操作 | 確認ダイアログ（§9）。破壊的な側は destructive ロール | ダイアログ |
| NAS 配布元未設定 | ブックマーク無し | サムネイル取得をスキップ、閲覧は既存キャッシュで | 保守タブに案内 |
| NAS 未到達 | ブックマーク解決失敗 / `fileExists` false | 取得・アップロードを保留 | バナー「NAS に接続できません（サムネイル取得は再接続後に再開）」 |
| 配布元にファイル無し | 読み取り 404 相当 | `lastError` 記録、次回再試行 | なし（保守タブの統計に件数） |
| 取得先の空き容量不足 | 事前チェック / 書き込み失敗 | 一括を停止 | 警告 |
| 従量課金回線（iPad） | `NWPathMonitor.isExpensive` | 一括は確認後のみ | 警告シート |
| KVS 上限超過 | `NSUbiquitousKeyValueStore` 書き込み失敗 | UserDefaults のみ更新 | 状態欄 |
| 初期インポートが長時間終わらない | import イベントの `endDate` が来ない | サムネイル初回フローを開始しない | 状態欄「初回同期中… N 件」 |

---

## 16. フェーズ計画と作業項目

### Phase 1: Mac 間の書誌メタデータ同期
1. 署名検証: iCloud エンタイトルメントを追加した Archive → Export → 公証を通す（§14.2）。
2. モデル改修（§4）: `.unique` 撤廃、デフォルト値、`bookmarkData` 分離、`coverVersion` / `coverBytes` 追加、`LocalBookmark` / `LocalCoverState`、マイグレーション。
3. `ItemFileAccess` / `VolumeRelocationView` / `LibraryImporter` を `LocalBookmark` 参照へ変更。インポートの重複排除（§4.8）。
4. `LibraryStore`（§5）: 2 構成コンテナ、モード決定、ホットスワップ、`ModelActor` 再生成。
5. アカウント監視（§7）: `accountStatus` / `CKAccountChanged` / `eventChangedNotification`、状態モデル。
6. 環境設定「iCloud」タブ（§8）。
7. 両側非空処理（§9）。
8. モード切替スナップショット（§6.6）とバックアップ対象の追加（§12）。
9. テスト: `SwiftTesting` で決定式・状態遷移・重複排除・マイグレーション（`bookmarkData → LocalBookmark`）を検証。CloudKit 実通信は 2 台の Mac での手動検証項目とする。

### Phase 2: サムネイル配布と設定同期
1. 配布元フォルダ選択とブックマーク（§10.2）。
2. 既存キャッシュの NAS 一括登録（§10.9）。
3. 生成側の NAS 書き込みと保留アップロード（§10.8）。
4. 対象集合計算・初回警告・一括取得エンジン・優先度制御（§10.3〜10.7）。
5. 掃除（§10.10）。
6. 共有設定の KVS ミラー（§11）。
7. 実測に基づく閾値調整（§10.11）。

### Phase 3: iPad
1. §13 の未決事項（本文閲覧方式）を決定。
2. AppKit 依存の抽象化とマルチプラットフォームターゲット。
3. `UIDocumentPicker` によるボリューム/配布元選択、Background Modes。
4. iPad 上での初回一括取得・従量回線警告の検証。

---

## 17. 未決事項・要確認事項

| # | 項目 | 状態 |
|---|---|---|
| Q1 | サムネイルキャッシュの実測容量（件数・合計・平均・最大） | ユーザーのターミナルで計測待ち。閾値と警告文の数値に反映 |
| Q2 | iPad で書籍本文を読むか（共有シート / 内蔵ビューア / 対象外） | 未決（Phase 3 着手前に決定） |
| Q7 | 置き換え後、`local.store` を消さずにブックマークを残す価値があるか | 現状は消す。Item / Volume の UUID が変わり対応づかないため |
| Q3 | ホットスワップの安定性 | **解決（不採用）。** 実装したところ破棄済みモデルへのアクセスでクラッシュしたため、再起動方式に一本化（§5.4） |
| Q4 | Developer ID + iCloud エンタイトルメントの署名・公証 | Phase 1 の最初に検証 |
| Q5 | 初回一括取得の閾値（500 件 / 50 MB）と並列数（8） | 初期値。実測後に調整 |
| Q6 | モード切替スナップショットの世代数（1） | 初期値 |

---

## 18. 用語

| 用語 | 意味 |
|---|---|
| 同期ストア / Library store | `default.store`。Item / Shelf / Volume / CoverExtractionRecord を保持。cloud モードでは CloudKit と同期 |
| ローカル専用ストア / Local store | `local.store`。LocalBookmark / LocalCoverState を保持。同期しない |
| 実効モード | 実際にコンテナを開いた構成（cloud / local）。設定スイッチとは区別する |
| 配布元 | NAS 上の `ShelfRowThumbnails/`。Mac が書き、全端末が読む |
| 対象集合 | `coverVersion > localVersion` を満たす Item の集合。サムネイル取得の単位 |
| 両側非空 | 初回 cloud 切替時にローカルにもクラウドにもレコードがある状態 |

---

## 19. Phase 1 実装記録（2026-09-19）

### 19.1 実装したもの

| 設計 | 実装 |
|---|---|
| §4 モデル改修 | `Item` / `Volume` / `Shelf` / `CoverExtractionRecord` から `@Attribute(.unique)` を撤廃し、全属性に宣言側デフォルト値を付与。`Item` に `coverVersion` / `coverBytes` を追加 |
| §4.5 `LocalBookmark` | `ShelfRow/LocalStore.swift`。`BookmarkVault`（`@MainActor`、辞書キャッシュ + 書き込み）経由で読み書きする |
| §4.8 重複排除 | `LibraryImporter` は元から `legacyID → Item` の辞書で fetch-before-insert しており、変更不要だった |
| §5 `LibraryStore` | `ShelfRow/LibraryStore.swift`。2 構成コンテナ、モード決定、再起動なしの再オープン、`generation` によるビュー再構築 |
| §6.6 スナップショット | `StoreFileBackup`。起動時 3 世代（`local.store` も対象に追加）+ cloud 切替直前の 1 世代 |
| §7 アカウント監視 | `ShelfRow/CloudAccount.swift`。`accountStatus` / `CKAccountChanged` / `eventChangedNotification` |
| §8 設定タブ | `PreferencesView` に `PreferencesPane.icloud` と `CloudSyncSettingsView` |
| §14.1 エンタイトルメント | CloudKit・KVS・ネットワークを追加 |

テスト: `LibraryModeTests`（モード決定の真理値表、Availability 判定）、`BookmarkVaultTests`（保存・削除・再読込・モデルからの移行が一度きりであること）。

### 19.2 設計からの変更点と理由

1. **`Item.bookmarkData` / `Volume.bookmarkData` を削除せず残した。**
   設計 §4.2 は削除としていたが、属性を消すと SwiftData の軽量マイグレーションが列ごと捨てるため、既存の 19,287 件が持つブックマークが移行前に失われる。`VersionedSchema` によるカスタム移行は旧モデル型一式の複製が必要で、ネストしたモデル型のエンティティ名の扱いに不確実さが残る。そこで**属性は残したまま、初回起動時に `BookmarkVault.adoptBookmarksStoredOnModels` が中身を `LocalBookmark` へ移して `nil` にする**方式にした。以後この列は常に空なので、CloudKit へ端末固有の値が流れることはない。**全端末がこのバージョンを一度起動した後、次のリリースで属性ごと削除してよい。**
   実測: 実ライブラリで 37 件のブックマークが移行され、次回起動で読み戻されることを確認済み。

2. **`LocalCoverState` は未実装。** サムネイル同期（Phase 2）でしか使わず、ローカル専用ストアへのモデル追加は軽量マイグレーションで済むため、前倒しの必要がない。`Item.coverVersion` / `coverBytes` は CloudKit スキーマが追加のみで変更できない都合があるので予定どおり先に入れた。

3. **§9 はマージをやめ、「どちらの蔵書を残すか」の選択に置き換えた（D12）。** スイッチのオン操作で確認ダイアログを出し、1台目はそのまま送信、2台目以降はローカルのストアファイルを削除してから iCloud に接続する。削除はレコード操作ではなくファイル削除で行い（レコード削除は iCloud へ伝播して全端末の蔵書を消すため）、コンテナが開いていない瞬間が必要なので再起動を挟む。

4. **`CloudKitEntitlement` を追加（設計になかった要素）。**
   `CKContainer(identifier:)` は、実行ファイルに一致するコンテナエンタイトルメントが無いとき**エラーを返さずトラップする**（`EXC_BREAKPOINT`）。署名なしのローカルビルドはこの状態になるため、起動直後に必ずクラッシュした。`SecTaskCopyValueForEntitlement` で権限の有無を確認してから CloudKit に触れるようにし、`LibraryStore.makeContainer` も cloud モード要求時に同じ確認をして `LibraryStoreError.cloudKitUnavailable` を投げる（→ ローカルへフォールバック）。

5. **プッシュのエンタイトルメントはキー名が違っていた（解決済み）。**
   当初 iOS 用の `aps-environment` を書いていたため、プロファイルが付与するキー（macOS は `com.apple.developer.aps-environment`）と一致せず、署名時に無言で削除されていた。この状態ではサイレントプッシュが届かず、他端末の変更の取り込みが起動時などに限られる。キー名を修正し、値はビルド設定 `APS_ENVIRONMENT`（Debug = development / Release = production）から取るようにして、署名済みバイナリに入ることを確認した。

### 19.3 検証済み / 未検証

| 項目 | 状態 |
|---|---|
| 実ライブラリ（19,287 件）のスキーマ移行 | ✅ 成功。件数・シェルフ・レート・表紙表示に欠落なし |
| ブックマークの `LocalBookmark` への移行 | ✅ 37 件、再起動後の読み戻しも確認 |
| ローカルモードでの通常動作 | ✅ |
| 設定「iCloud」タブ | ✅ 状態「利用可能」、アカウント ID 表示、モード「ローカル」 |
| 有効化時の確認ダイアログ | ✅ 表示・キャンセルを確認（どちらの選択肢も未実行） |
| Developer ID + iCloud での Archive / 公証 | ❌ 未実施（Q4） |
| **iCloud 同期をオンにした実動作** | ❌ **未実施。** ライブラリを iCloud へ初回アップロードする操作であり、利用者の明示的な同意が要る |
| 2 台目の端末での受信 | ❌ 未実施 |
| モード切替（オン↔オフ） | ⚠️ ホットスワップはクラッシュしたため廃止し、再起動方式へ変更（§5.4）。再起動方式での往復は未検証 |
| CloudKit スキーマの Production デプロイ | ❌ 未実施（§14.3） |

### 19.4 次にやること

1. Apple Developer の Identifiers で App ID に Push Notifications を有効化し、`aps-environment` が署名に入ることを確認する。
2. 1 台目で iCloud 同期をオンにし、初回アップロードと `eventChangedNotification` の挙動、ホットスワップの安定性（Q3）を確認する。
3. 2 台目は §9 の「iCloud の蔵書で置き換える」で接続し、ボリュームのアクセス権を再設定する。
4. Developer ID での Archive・公証を通す（Q4）。リリース前に CloudKit スキーマを Production へデプロイする。
