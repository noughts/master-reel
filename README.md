# Master Reel（master-reel）

macOS の VideoToolbox に入っている AI 超解像（`VTSuperResolutionScaler`）を使って、動画を高解像度化する CLI です。
848x480 の動画なら 3392x1920 に、縦横それぞれ 4 倍に拡大します。

## 必要な環境

- macOS 26 以降の Apple シリコン Mac（macOS 27.0.1 / M5 で動作を確認）
- ビルドには Xcode 26 以降（Swift 6.2 以降）
- 超解像の ML モデルは OS が管理しています。未取得の場合は初回実行時に自動でダウンロードされ、進捗が表示されます。

## ビルド

```bash
swift build -c release
```

実行ファイルは `.build/release/master-reel` にできます。

## 使い方

```bash
.build/release/master-reel 入力.mp4 出力.mp4
```

- 出力のコンテナ形式は拡張子（`.mov` / `.mp4` / `.m4v`）で決まります。
- 出力ファイルが既にある場合は上書きせず、エラーで終了します。
- 処理中は標準エラーに進捗（割合・処理済みフレーム数・速度・残り時間）を表示します。

### オプション

| オプション | 説明 |
|---|---|
| `--video` | 動画モードで超解像します（後述） |
| `-h`, `--help` | ヘルプを表示します |

## Finder の右クリックから使う

```bash
QuickAction/install.sh
```

リリースビルドを行い、クイックアクション「超解像」を `~/Library/Services/Master Reel.workflow` にインストールします。
再実行すると、ビルドし直したものに置き換わります。

- Finder で動画を右クリックし、「超解像」を選ぶと実行されます。
- 出力は入力と同じフォルダに `元の名前-4x.拡張子` で書き出します。
  - 拡張子が `.mov` / `.mp4` / `.m4v` 以外の入力は `.mov` で書き出します。
  - 同じ名前のファイルがあれば `元の名前-4x 2.拡張子` のように番号を付けます。
- 画像モード（既定）で処理し、完了・失敗は通知で知らせます。集中モード中はバナーが出ず、通知センターに残ります。
- 「デスクトップ」「書類」「ダウンロード」の動画で初めて使うときは、フォルダへのアクセス許可を求めるダイアログが出ます。
- アンインストールするには `~/Library/Services/Master Reel.workflow` を削除します。

| ファイル | 役割 |
|---|---|
| `QuickAction/install.sh` | ビルドしてインストールする |
| `QuickAction/Master Reel.workflow/Contents/Info.plist` | メニュー名と、表示する条件（Finder で動画を選んだとき） |
| `QuickAction/Master Reel.workflow/Contents/document.wflow` | Automator のワークフロー本体。`run-quick-action` を呼ぶだけ |
| `QuickAction/Master Reel.workflow/Contents/Resources/run-quick-action` | 出力名を決めて `master-reel` を実行し、結果を通知する |

## 2 つのモード

| | 画像モード（既定） | 動画モード（`--video`） |
|---|---|---|
| 処理の仕方 | 各フレームを独立に処理 | 前のフレームとその超解像結果を参照して処理 |
| 仕上がり | 細部が残りやすい | 細部は控えめで、フレーム間のちらつきが抑えられる |
| 入力の上限 | 1920x1920 | 1920x1080 |
| 速度の目安 | 5 秒・848x480 の動画で約 20 秒 | 同じ動画で約 27 秒 |

画像モードでは、細かい模様がフレームごとにわずかにちらつくことがあります。気になる場合は `--video` で見比べてください。
動画モードは縦長の入力（1080x1920 など）を受け付けません。縦長の動画は画像モードで処理してください。

## 出力

- **映像**:
  - HEVC Main10 で書き出します。
  - 超解像の出力は 16 bit 浮動小数なので、階調を保てる 10 bit で書き出します。
  - 色空間（BT.709、HLG / BT.2020 など）と回転情報は入力から引き継ぎます。
- **音声**: 再エンコードせず、そのままコピーします。

## 開発

```bash
swift test
```

| テスト | 内容 |
|---|---|
| `ArgumentsTests` | 引数の解析 |
| `EncodingSettingsTests` | 出力形式・エンコード設定 |
| `ProgressTests` | 進捗表示の文字列 |
| `SuperResolutionTests` | 実際に VideoToolbox で超解像する統合テスト。`Tests/MasterReelTests/Fixtures` の小さな動画を使う |

`SuperResolutionTests` は、超解像に対応していない Mac では自動でスキップされます。

### ソースの構成

| ファイル | 役割 |
|---|---|
| `main.swift` | エントリポイント。引数を解析して実行し、終了コードを返す |
| `Arguments.swift` | 引数の解析とヘルプ文 |
| `SuperResolution.swift` | 動画の読み込み・超解像・書き出し |
| `EncodingSettings.swift` | 出力のコンテナ形式とエンコード設定 |
| `Progress.swift` | 進捗表示の文字列を作る |
