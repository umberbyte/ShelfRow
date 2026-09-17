
# AI Agent Instructions for Swift Development

## 1. アーキテクチャと型安全性（バグ抑制・高品質化）
* **Swift 6 完全準拠**: データ競合のない安全なコードを生成すること。厳格な並行性チェック（Strict Concurrency）を満たし、`Sendable` プロトコルへの適合を必須とする。
* **強制アンラップの禁止**: `!`（Force Unwrap）や `try!` は原則禁止。`guard let`、`if let`、または `nil-coalescing (??)` を徹底する。
* **状態管理の近代化**: Combine や `@StateObject` ではなく、Observation フレームワーク（`@Observable`）を標準採用し、不要なプロパティ監視やライフサイクル事故を防ぐ。
* **テストファースト**: 新規ロジックや機能追加時は `Swift Testing`（`@Test`, `#expect`）を用いたユニットテストを必ず同一ターンで作成する。
* **ログ設計**: 生の `print` 文は禁止。`os.Logger` を用いて適切なサブシステムとカテゴリ、ログレベル（debug, info, error）で構造化ログを記録する。

## 2. マシンパワーの極限活用（Apple Silicon 最適化・高速化）
* **構造的並行処理（Structured Concurrency）**:
  * スレッドを直接生成しない。非同期処理には `async/await`、並列処理には `withTaskGroup` または `async let` を使用する。
  * UI描画に関わらない重い計算処理・画像/音声処理・JSONデコードは、明示的に非メインアクター（バックグラウンド Task やカスタム Actor）にオフロードする。
* **ハードウェアアクセラレーション**:
  * 行列計算、数値解析、DSP処理には `Accelerate.framework`（vDSP / BLAS）を優先採用する。
  * 機械学習モデルの推論は CPU を避け、Core ML 経由で Apple Neural Engine (ANE) / GPU にディスパッチされるよう `.all` または `.cpuAndGPU` を明示する。
* **メモリ効率と値型セマンティクス**:
  * クラス（`class`）より構造体（`struct`）を優先し、ヒープアロケーションを抑制する。
  * 不要な参照循環（強参照サイクル）を防ぐため、クロージャキャプチャでは `[weak self]` を適切に使い分ける。

## 3. セキュリティとプライバシー保護
* **シークレット管理**:
  * APIキー、認証トークン、機密パラメータをリポジトリ内のコードや `Info.plist` に平文で記述しない。
  * トークンや認証情報の保存には必ず `KeychainServices`（または LocalAuthentication + Secure Enclave）をラップした型を経由する。
* **データ保護（Data Protection）**:
  * 端末ローカルに書き込む機密ファイルは、ファイル書き込みオプションに `.completeFileProtection` を指定する。
* **入力値バリデーション**:
  * DeepLink（URL Scheme / Universal Links）や外部APIからの入力は、バリデーションとサニタイズを境界層で行う。

## 4. UI応答性とユーザビリティ（UX向上）
* **メインスレッド保護**:
  * 画面描画や `@Observable` のUIバインドプロパティの更新は、必ず `@MainActor` で隔離する。メインスレッドのブロック（コマ落ち・ヒッチ）を絶対に発生させない。
* **SwiftUI 再描画の最小化**:
  * View の `body` 内で重い計算や非同期処理の直接起動（`.onAppear` 内での同期処理など）を行わない。
  * 大規模リストには `LazyVStack` / `LazyHStack` を適用し、画面外のセル描画負荷を抑制する。
* **即時フィードバック**:
  * 待機時間が発生する処理には、スケルトンビューや `ProgressView`、オプティミスティックUI（先行画面更新）を組み込む。
  * 成功・エラー・主要アクションには `UIImpactFeedbackGenerator` などの適切な Haptics を添える。
* **アクセシビリティ標準準拠**:
  * カスタムコンポーネントには `.accessibilityLabel`、`.accessibilityValue`、`.accessibilityHint` を付与する。
  * 文字列やレイアウトは Dynamic Type に対応し、固定サイズ指定による文字欠けを防ぐ。

---

### 実装判断マトリクス

| 領域 | 推奨（Do） | 非推奨・禁止（Don't） |
|---|---|---|
| **並行処理** | `Task`, `TaskGroup`, `actor` | `DispatchQueue.global()`, `Thread.sleep` |
| **状態監視** | `@Observable class ViewModel` | `@Published`, `ObservableObject` |
| **データ保存** | Keychain, SwiftData, CoreData | `UserDefaults` への機密データ保存 |
| **データ構造** | `struct`, `enum`（値型・イミュータブル） | 状態を持たない不要な `class` 乱用 |
| **エラー処理** | 独自定義の `enum: Error` と `throw` | 戻り値 `nil` によるエラーの握りつぶし |
