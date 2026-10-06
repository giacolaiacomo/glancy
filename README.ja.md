<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="Glancy のアイコン">

# Glancy

**MacBook のノッチを、ちゃんと使える場所に。**<br>
コーディングエージェント、次の会議、音楽、メモ、クリップボード、ウインドウをひと目で。

<a href="https://github.com/giacolaiacomo/glancy/releases/latest/download/Glancy.dmg"><img src="docs/download.svg" width="280" height="60" alt="macOS 版をダウンロード"></a>

<sub>macOS 14 以降 · Apple シリコンと Intel · 署名・公証済み · 自動アップデート</sub><br>
<sub>Homebrew なら：<code>brew install --cask giacolaiacomo/tap/glancy</code>（<a href="#homebrew">詳細</a>）</sub>

<br>

<a href="https://github.com/giacolaiacomo/glancy/releases/latest"><img src="https://img.shields.io/github/v/release/giacolaiacomo/glancy?label=release&color=1F9AA6" alt="最新リリース"></a>
<a href="https://github.com/giacolaiacomo/glancy/releases"><img src="https://img.shields.io/github/downloads/giacolaiacomo/glancy/total?color=1F9AA6" alt="ダウンロード数"></a>
<a href="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml"><img src="https://github.com/giacolaiacomo/glancy/actions/workflows/build.yml/badge.svg" alt="Build"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
<img src="https://img.shields.io/badge/Swift-1%20dependency%20(Sparkle)-F05138?logo=swift&logoColor=white" alt="Swift、依存はひとつ（Sparkle）">
<img src="https://img.shields.io/badge/RAM-~18%20MB-2ea44f" alt="メモリ約 18 MB">
<img src="https://img.shields.io/badge/telemetry-none-2ea44f" alt="テレメトリなし">
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>

<sub><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <b>日本語</b></sub>

</div>

<br>

<p align="center">
  <img src="docs/screens.jpg" alt="Glancy のタブ：ホーム、Agents、カレンダー、メディア、メモ、コマンドバー、コントロール、モニター、クリップボード、ウインドウ">
</p>
<p align="center"><sub>画像はすべて架空のデモデータです。</sub></p>

Glancy はノッチを小さなライブ表示エリアに変えます。閉じているときはハードウェアのノッチそのまま。何かが起きると左右に「ウイング」が伸びます。ホバーでのぞき見、クリックでパネル全体を開きます。

**軽さを最優先に設計：** アイドル時のメモリは約 18 MB、CPU 時間は 1 分あたり 0 秒。ノッチが閉じている間はタイマーもポーリングも動かず、すべてシステムイベントで動きます。データが Mac の外に出ることはありません。

## ハイライト

| モジュール | できること |
|---|---|
| **Agents** | Claude Code、Codex、OpenCode のセッションをひとつのボードに：作業中、**あなた待ち**、完了。クリックでターミナルやエディタへ。 |
| **カレンダー** | 次の会議をカウントダウン付きで表示し、**Join** ボタン（Zoom、Meet、Teams、Webex、Whereby、FaceTime）。 |
| **メディア** | ブラウザを含むあらゆるプレーヤーの再生中の曲を、操作ボタンと出力デバイス付きで。 |
| **メモ** | チェックボックス付きのプレーンテキスト `.md` メモと、この Mac 上で文字起こしされる**ボイスメモ**。 |
| **コマンドバー** | ⌃⌥K：アプリ、計算機、単位と通貨の換算、各モジュールのコマンド。 |
| **クリップボード** | 直近 60 件のコピーを検索・ピン留め（⌥⌘V）。パスワードは記録しません。 |
| **ウインドウ** | ノッチにライブのグリッドマップ、自動整列、ワークスペース。どの操作もプレビューされ、取り消せます。 |
| **ほかにも** | コントロールのスイッチ、システムモニター、タイマーとポモドーロ、ファイルのシェルフ、控えめな音量／明るさ HUD、バッテリーと AirPods。 |

**画面に合わせて：** 設定 → 一般 → **サイズ**（Size：Normal、Large、Extra large）でパネル全体を拡大でき、大きな画面や高解像度のディスプレイに便利です。**常に最新：** Glancy はアプリ内で自動的にアップデートします。

## 機能

モジュールをクリックすると詳細が開きます。

<details>
<summary><b>ノッチ</b>：閉じる、のぞき見、開く</summary>

- **閉じているとき：** ハードウェアのノッチそのままです。何かが起きると左右にウイングが伸び、いちばん大事なライブ情報を表示します。あなたを待つエージェント、まもなく始まる会議、タイマー、音量表示、再生中の曲など。
- **のぞき見：** ホバーするとヒントを表示。セッションの完了、AirPods の接続、曲の切り替えなどのときは短いドロップダウンで知らせます。
- **開いたとき：** クリックするとタブ付きのパネルが開きます。Esc、外側のクリック、カーソルを離すと閉じます。
- ウイングがメニューやステータス項目に重なることはありません。ノッチがない場合（ノッチのない Mac、または外部ディスプレイにつないで閉じた MacBook）は画面上部中央に小さなピルを表示。追加のディスプレイでは任意です。
- **サイズ**（Size）：設定 → 一般で Normal、Large、Extra large から選べます。画面に収まらないサイズのときは Glancy が知らせます。
- スクリーンショットや画面共有には映りません（設定で変更可、デフォルトはオン）。英語とイタリア語に対応。

</details>

<details>
<summary><b>Agents</b>：Claude Code、Codex、OpenCode</summary>

- Claude Code（ターミナル、VS Code、Cursor、Claude アプリ）、Codex（CLI、VS Code、Codex アプリ）、OpenCode をひとつのボードに。
- 稼働中のセッションをウイングにドットで表示：作業中、**許可待ち**（琥珀色）、完了、失敗。
- Agents タブ：各セッションのプロジェクト、状態、その状態の経過時間、最後に使ったツール、最後のプロンプト。
- セッションをクリックすると前面に：そのターミナル（Terminal、iTerm、Ghostty、Warp）、エディタのウインドウ（VS Code、Cursor）、または Codex アプリ。⌥クリックで前面に出してタイル配置。
- **Lay out sessions** で Claude のターミナルをまとめてタイル配置。適用前にプレビューされ、元に戻せます。
- Claude Code には小さな hook が必要です（[設定](#claude-code)）。Codex と OpenCode は設定不要です（[設定](#codex-と-opencode)）。Glancy は読み取るだけで、エージェントと通信することはありません。

</details>

<details>
<summary><b>カレンダー</b>：次の会議と Join</summary>

- 次の会議をカウントダウン付きで表示し、Zoom、Google Meet、Teams、Webex、Whereby、FaceTime のリンクには **Join** ボタン。
- カレンダータブで今日と明日の予定をカレンダーの色で表示。辞退した予定は非表示、対象のカレンダーも選べます。

</details>

<details>
<summary><b>メディア、HUD、バッテリー、AirPods</b></summary>

- ブラウザを含む**あらゆる**プレーヤーの再生中の曲：アートワーク、再生位置、再生／一時停止、前へ／次へ、出力デバイス。ウイングはアートワークの色に。曲が変わると短く表示します。
- 音量、明るさ、キーボードバックライトのオーバーレイを、ノッチの控えめな表示に置き換えます（⌥⇧ で 1/4 ステップ）。
- 電源の接続・取り外し、バッテリー残量低下、低電力モードを短く表示。
- AirPods などのヘッドホンが接続されると、左右とケースのバッテリー残量を表示。

</details>

<details>
<summary><b>タイマー、ポモドーロ、シェルフ</b></summary>

- 5、15、25、50 分またはカスタム、25/5 のポモドーロサイクル。ウイングにリング表示、終了時に通知。再起動しても続きます。
- ファイルをノッチにドラッグして一時的に置いておき、あとで好きな場所へドラッグ。シェルフから AirDrop、共有、クイックルック。最大 24 項目、再起動後も保持。

</details>

<details>
<summary><b>メモとボイスメモ</b></summary>

- プレーンテキストの `.md` メモを Finder で開けるフォルダに保存し、入力と同時に保存します。`- [ ] ` でチェックボックスになり、メモはホームにピン留めできます。⌃⌥N でメモを開きます。
- **ボイスメモ：** どのアプリからでも ⌃⌥V で録音の開始と停止（5、15、30、60 分で自動停止、デフォルトは 30 分）。`.m4a` としてメモの隣に保存され、再生やドラッグでの書き出しができます。
- **文字起こし**はデフォルトでオンで、すべてこの Mac 上で行われます（オンデバイスの音声認識）。どこにも送信されません。

</details>

<details>
<summary><b>コマンドバー</b></summary>

- ⌃⌥K ですべてを横断する検索欄を開きます：アプリ、計算機、単位と通貨の換算（レートは ECB から、通貨の検索を入力したときだけ取得）、ウェブ検索、各モジュールのコマンド（次の会議に参加、1 時間スリープさせない、ワークスペースを保存、CPU 使用率の上位…）。⏎ で実行、⌘⏎ でサブのアクション。
- よく使うものを学習します。各ソースは設定 → コマンドバーでオフにできます。

</details>

<details>
<summary><b>クリップボード履歴</b></summary>

- 直近 60 件のコピー：テキスト、リッチテキスト、リンク、画像、ファイル。検索とピン留めに対応。⌥⌘V で開きます。
- パスワードや、アプリが非表示・一時的と指定した内容、パスワードマネージャーからのコピーは記録しません。一時停止、アプリごとの除外、消去も可能。

</details>

<details>
<summary><b>ウインドウ</b>：グリッドマップ、自動整列、ワークスペース</summary>

- ノッチにディスプレイのライブマップ：セルにホバーすると実際の画面でプレビュー、クリックで配置。
- グリッド（2×1 から自由なサイズまで）を選び、画面全体、ひとつのアプリ、または選んだウインドウ（⌘クリックで順番に）を整列。方式：Balanced、1 セル 1 枚、列、行、メイン＋スタック。
- ウインドウをノッチにドラッグしてセルにドロップ。キーボード：⌃⌥Space でマップを開く、⌃⌥←/→/↑/↓ で左右半分・最大化・元に戻す、⌃⌥F でフィット、⌃⌥B/C/R/M/G で整列（⇧ を加えると最前面のアプリだけ）、⌃⌥Z で取り消し。ショートカットはすべて変更できます。
- **自動整列**（⌃⌥A）：ポインタのあるディスプレイのウインドウに合うレイアウトを選んですぐ適用（⇧ で最前面のアプリだけ）。⌃⌥Z で取り消し。
- **ワークスペース：** すべてのディスプレイ上の各ウインドウの位置を保存し、ワンクリックで復元。それぞれにショートカットも設定できます。復元時に足りないアプリは起動し、そのディスプレイ構成がつながったときに自動で適用することもできます。
- どの整列も適用前にプレビューされ、取り消せます。

</details>

<details>
<summary><b>コントロールとモニター</b></summary>

- **コントロール：** スイッチ（スリープさせない、ダークモード、Wi-Fi、デスクトップアイコン、隠しファイル）と単発のツール（ロック、ディスプレイをオフ、スクリーンセーバー、スクリーンショット、カラーピッカー、カメラのミラー、ゴミ箱を空にする、すべて取り出す）。スリープさせない時間を指定でき、終了時刻を表示。ゴミ箱を空にする前には確認します。
- **モニター：** 左に CPU、メモリ、GPU、ディスク、ネットワーク、エネルギーの指標、右に選んだ指標の上位アプリ（またはプロセス）。一覧から終了や強制終了ができます（強制終了は確認あり）。サンプリングはタブを開いている間だけ（1 秒または 2 秒ごと、選択可）。

</details>

<details>
<summary><b>通知</b>（オプトイン、実験的）</summary>

- 最近の通知をアプリごとにタブで表示し、届いたときは短く表示。アプリごとにミュート可能。デフォルトはオフで、（読み取り専用で）読むにはフルディスクアクセスが必要です。

</details>

## インストール

**macOS 14 Sonoma 以降**が必要です。Apple シリコンと Intel の両方で動作し、ノッチ付きの MacBook 向けに作られています（ノッチがなくても動きます。[制限事項](#制限事項)を参照）。

### ダウンロード

1. **[Glancy.dmg をダウンロード](https://github.com/giacolaiacomo/glancy/releases/latest/download/Glancy.dmg)**（常に最新リリース）して開き、**Glancy** をアプリケーションフォルダにドラッグします。
2. 開きます。Developer ID で署名され Apple の公証を受けているので普通に開け、アップデート後も権限が保たれます。
3. 初回起動時、ノッチに短い**権限チェックリスト**が表示されます。どの権限も任意なので、必要なものだけ許可してください（[各権限の役割](#権限)）。

Mac と一緒に起動するには、設定 → 一般 で**ログイン時に開く**（Launch at login）をオンにします。

### Homebrew

```sh
brew trust giacolaiacomo/tap        # 一度だけ：最近の Homebrew はサードパーティの tap から cask を読み込む前に確認します
brew install --cask giacolaiacomo/tap/glancy
```

同じ公証済みのアプリがインストールされます。削除：`brew uninstall --cask glancy`（`--zap` を付けるとデータと設定も削除）。ソースからビルドする旧 formula をインストールしていた場合は、先に `brew uninstall glancy` を実行してください。

### ソースからビルド

```sh
git clone https://github.com/giacolaiacomo/glancy.git
cd glancy
./install.sh
```

`~/Applications/Glancy.app` をビルドし、**ログイン時に開く**をオンにして起動します。アップデート：`git pull && ./install.sh`。データ、設定、権限ごと削除：`./uninstall.sh`。

ビルドには Swift 6.2 ツールチェーン（Xcode 26 またはそのコマンドラインツール：`xcode-select --install`）と `cmake`（`brew install cmake`）が必要です。キーチェーンに "Apple Development" 証明書があれば `scripts/build-app.sh` は最初のものを使って署名するので、再ビルドしても権限が保たれます。なければ ad-hoc 署名になります。`GLANCY_SIGN_IDENTITY` で指定することもできます。

### アップデート

Glancy は [Sparkle](https://sparkle-project.org) で自動的にアップデートします。新しいバージョンがあると、パネル上段の歯車の隣に緑の矢印が表示されます。クリックすると変更内容を確認してインストールできます（Glancy は自動で再起動します）。**今すぐ確認**（Check now）と**アップデートを自動的に確認**（Check for updates automatically）は設定 → 一般にあり、コマンドバーにも **Check for Updates** があります。アップデートは署名（EdDSA、Sparkle が検証）と公証済みです。Homebrew はアプリが自動アップデートすることを把握しているので `brew upgrade` は触れません。`brew upgrade --cask glancy` も使えます。

## エージェントの設定

### Claude Code

Agents モジュールは、小さな Claude Code の hook が書き出すログを読みます。Glancy が Claude の設定を変更することはないので、この手順はご自身で行ってください。

1. hook をコピー（このリポジトリのクローン内で）：`mkdir -p ~/.claude/hooks && cp hooks/cc-dashboard-event.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/cc-dashboard-event.sh`
2. `~/.claude/settings.json` に次の 7 つのイベントで追加します（既存の `hooks` とマージし、`YOU` は自分のユーザー名に置き換えてください）。

<details>
<summary><code>settings.json</code></summary>

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }],
    "StopFailure":       [{ "hooks": [{ "type": "command", "command": "/Users/YOU/.claude/hooks/cc-dashboard-event.sh", "timeout": 5 }] }]
  }
}
```

</details>

hook はイベントごとに `~/.claude/hooks/data/cc-dashboard/events.jsonl` へ 1 行追記します：時刻、イベント名、セッション ID、作業フォルダ、ツール名、プロンプトの先頭 200 文字、そしてセッションが動いているアプリ（アプリのバンドル ID、`TERM_PROGRAM`、Claude Code のエントリポイント。これにより VS Code のセッションは VS Code を、ターミナルのセッションはターミナルを開きます）。何も出力せず、常に終了コード 0 で終わるので、Claude Code を止めることはありません。`jq` が必要で、macOS 15 以降には標準で入っています（macOS 14 では `brew install jq`）。同じ hook がターミナル、VS Code と Cursor の拡張機能、Claude アプリで動作します。古い hook もそのまま使えます。その場合、ノッチを開いたときにプロセスツリーからアプリを特定します。

### Codex と OpenCode

設定は不要です。各ソースは設定 → Agents でオフにできます。

- **Codex**（CLI、Codex アプリ、VS Code 拡張機能）：Codex が `~/.codex/sessions/` に書き出すセッションファイルを読み取り専用で追います。ターンの実行、完了、失敗、あなたの回答や承認待ちを検知します。クリックすると Codex アプリや VS Code でセッションを開くか、そのターミナルを前面に出します。`config.toml`（とその `notify` コマンド）には一切触れません。
- **OpenCode：** OpenCode 自身のデータベース（`~/.local/share/opencode/opencode.db`、読み取り専用）から作業中／完了／失敗を読み取ります。権限待ちも表示したい場合は、設定 → Agents → OpenCode で **Install** をクリックしてください。[`hooks/glancy-opencode.js`](hooks/glancy-opencode.js) を `~/.config/opencode/plugins/glancy.js` にコピーします（`opencode.json` は編集せず、すでにある別のファイルはバックアップとして残します）。**Uninstall** で削除します。

## 権限

すべての権限は任意です。ない場合、そのモジュールの機能が少し減るだけです。設定 → 権限 で状態を確認し、ボタンから許可できます。

| 権限 | できること | ない場合 |
|---|---|---|
| **カレンダー** | 次の会議、Join ボタン、カレンダータブ | カレンダーなし |
| **アクセシビリティ** | HUD のキー処理、ウインドウのタイル配置、セッションのターミナルへの移動、クリップボードでの ⌘C の検知と選択後の貼り付け、メニュー幅の計測（左のウイングがメニューに重ならないように） | システムの HUD のまま、タイル配置なし、クリップボードはアプリ切り替え時やノッチを開いたときに記録、左のウイングは非表示 |
| **Bluetooth** | AirPods やヘッドホンの接続とバッテリー | ヘッドホンの表示なし |
| **通知** | タイマー終了時の通知 | タイマーはノッチ内で静かに終了 |
| **オートメーション**（ミュージック、Spotify） | この 2 つのアプリ用の予備の読み取り。メインの読み取りがその macOS で動かない場合だけ使用 | メインの読み取りでメディアは動作 |
| **マイク** | ボイスメモとマイクのミュートショートカット | ボイスメモなし、マイクのミュートなし |
| **音声認識** | ボイスメモの文字起こし（この Mac 上で） | 録音は音声のみ |
| **カメラ** | コントロールタブのカメラのミラー | ミラーなし |
| **フルディスクアクセス** | macOS の通知データベースの読み取り。通知モジュールをオンにした場合のみ | 通知モジュールはオフのまま |

## よくある質問

<details>
<summary><b>システム設定でアクセシビリティはオンなのに、Glancy は許可がないと言う</b></summary>

そのスイッチは古いエントリ（署名の異なる以前のバージョンやビルド）のもので、macOS がもうこのアプリと結びつけていません。Glancy の設定 → 権限 でアクセシビリティの横の **Allow…** を押してください。Glancy が自分の古いエントリを消して改めて許可を求めるので、スイッチをオンにすれば有効になります。手動でもできます：システム設定 → プライバシーとセキュリティ → アクセシビリティで Glancy を選び、**−** で削除してから **+** で追加し直します。

</details>

<details>
<summary><b>Glancy が見当たらない</b></summary>

Glancy はノッチに住んでいて、Dock アイコンはありません。ポインタをノッチに乗せるとのぞき見、クリックで開きます。ノッチのない Mac や、外部ディスプレイにつないで閉じた MacBook では、メインディスプレイの上部中央に小さなピルを表示します。設定 → 一般の **Pill on external displays** で他のディスプレイにも表示できます。

</details>

<details>
<summary><b>大きなディスプレイで文字が小さすぎる</b></summary>

設定 → 一般 → **サイズ**（Size）：Normal、Large、Extra large。パネル全体が拡大されます。画面に収まらないサイズの場合は、設定の下に Glancy が表示します。

</details>

<details>
<summary><b>アップデートの方法は？</b></summary>

何もする必要はありません。新しいバージョンが出ると、パネルの歯車の隣に緑の矢印が表示されるので、クリックしてインストールします。すぐに確認するには、設定 → 一般 → **今すぐ確認**（Check now）、またはコマンドバーの **Check for Updates**。Homebrew なら `brew upgrade --cask glancy` も使えます。[アップデート](#アップデート)を参照。

</details>

## プライバシー

Glancy にはテレメトリもアカウントもありません。定期的な通信は**アップデート確認**だけです：このリポジトリの最新の GitHub リリースから `appcast.xml` を取得します（起動時と、その後パネルを開いたときに最大 1 日 1 回。設定 → 一般でオフにできます）。為替レートは、コマンドバーで通貨を入力したときだけ ECB から取得します。それ以外はすべてローカルで読み取ります。

- **Claude Code：** 上記の hook ログを末尾から読み取り専用で。Glancy が書き込んだり、Claude を実行したりすることはありません。
- **Codex：** `~/.codex/sessions/` のセッションファイルを読み取り専用で（保持するのはセッションのフォルダ、状態、最初のプロンプト、最後のツール、最後の返答だけで、メモリ上のみ）。
- **OpenCode：** そのデータベースを読み取り専用で開きます。プラグインをインストールした場合は、それが `~/Library/Application Support/Glancy/agents/` に書くイベントログも。
- **カレンダー：** EventKit 経由の予定。メモリ上のみ。
- **メディア：** [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)（アプリに同梱され、システムの Perl で動く小さなヘルパー）が出力する、システムの再生中情報。予備としてミュージックと Spotify には AppleScript。
- **クリップボード：** コピーした内容を `~/Library/Application Support/Glancy/clipboard/`（本人のみアクセス可）に保存。非表示指定の内容とパスワードマネージャーは除外。いつでも消去できます。
- **メモとボイスメモ：** `~/Library/Application Support/Glancy/notes/` の `.md` と `.m4a` ファイル。文字起こしはこの Mac 上で行われます。
- **通知：** モジュールをオンにした場合のみ、macOS の通知データベースを読み取り専用で開きます。
- **ウインドウ：** マップを描くため、アクセシビリティ経由でウインドウのタイトルと位置を取得。保存するのはグリッド、レイアウト、ショートカットだけです。

設定は `~/Library/Preferences/ai.glancy.app.plist`、データ（クリップボード、シェルフ、メモ、タイマー、ウインドウのレイアウト）は `~/Library/Application Support/Glancy/` にあります。`./uninstall.sh` ですべて削除されます。詳しくは [SECURITY.md](SECURITY.md) を参照してください。

## 制限事項

- **ノッチのためのアプリです。** ノッチがなくても上部中央のピルで動作しますが、本来の使い方ではありません。
- **一部の機能にはアクセシビリティが必要です。**[権限](#権限)を参照してください。
- **ウインドウのタイル配置はアプリ次第です。** 最小サイズより小さくできないアプリや、自分でウインドウを動かすアプリがあります。Glancy はそうしたウインドウをセルの端にそろえ、ぴったり収まらなかったものを知らせます。タイル配置は Glancy でいちばん新しい機能で、他の部分ほど実際の使用で鍛えられていません。
- **証明書なしで自分でビルドしたもの**は ad-hoc 署名になり、再ビルドのたびに権限が外れます。macOS が新しいアプリとして扱うためです。システム設定で再度許可してください。
- **通知は実験的な機能です。** macOS の通知データベースは非公開で仕様もありません。読み取り側でスキーマを確認し、知らない形式なら自動でオフになります。検証はテスト用データでのみ行っており、macOS の各バージョンでは確認していません。
- **メディア**は mediaremote-adapter を通じて macOS の非公開フレームワークに依存しています。将来の macOS で動かなくなった場合は、ミュージックと Spotify だけに切り替わります。再生中情報のヘルパーは別プロセスで約 5 MB あり、Glancy 本体の約 18 MB とは別です。

## 開発

```sh
swift build && swift test                      # 警告 0 が前提
scripts/lint.sh                                # 閉じている間のタイマー、ポーリング、マウス移動の監視を禁止
.build/debug/Glancy --self-test                # 全モジュールのヘッドレスチェック（CI でも実行）
scripts/render.sh                              # すべての表示状態を render-out/ に PNG で出力（実データを使用、--it でイタリア語）
scripts/screenshots.sh                         # README の画像を再生成（架空のデモデータ）
scripts/build-app.sh build/Glancy.app          # アプリをビルド（UNIVERSAL=1 で Apple シリコンと Intel の両対応）
scripts/footprint.sh                           # アイドル時のメモリと CPU
Glancy --diagnose                              # 起動中のアプリの状態（モジュール、ディスプレイ、リソース）
```

各モジュールは `Sources/GlancyKit/<Module>/` にあり、`GlancyModule`（開始、停止、表示状態、タブ、ホームカード）を実装し、`Modules.swift` で登録します。Glancy を軽く保つルールは、ノッチが閉じている間はタイマー、アニメーション、ポーリングを一切動かさず、システムイベントの監視だけにすること。`scripts/lint.sh` がこれをチェックします。詳しくは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

リリース：公証済みの DMG はメンテナーの Mac で `scripts/make-dmg.sh` によって作られます。このスクリプトは `Glancy-x.y.z.dmg`、固定のダウンロードリンク用にバイト単位で同一の `Glancy.dmg`、Sparkle の `appcast.xml` を書き出し、3 つともリリースに添付されます。リリースを公開すると [release.yml](.github/workflows/release.yml) も実行され、タグからユニバーサル版をビルドして検証します。

## コントリビュート

バグ報告やアイデアは [Issues](https://github.com/giacolaiacomo/glancy/issues) へどうぞ。`Glancy --diagnose` の出力があると助かります。プルリクエストでは上記のノッチが閉じているときのルールを守り、`swift test` と `scripts/lint.sh` を実行してください。セキュリティの問題は [SECURITY.md](SECURITY.md) を参照してください。

## クレジット

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)、Jonas van den Berg とコントリビューター（BSD 3-Clause）。`Vendor/` に同梱し、再生中情報の読み取りに使用。
- [Sparkle](https://sparkle-project.org)（MIT）：アプリ内アップデート。
- [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit)（MIT）：フルスクリーンのスペースを検出する手法。
- [Tessera](https://github.com/giacolaiacomo/tessera)（MIT）：タイル配置エンジンの出発点となったグリッド、整列、ショートカットのロジック。ウインドウ配置の細部は Rectangle（MIT）を参考にしています。

詳細な表記は [NOTICE](NOTICE) と [Sources/GlancyKit/Tiling/NOTICE.md](Sources/GlancyKit/Tiling/NOTICE.md) にあります。GPL のコードは含まれていません。他のノッチアプリは参考として読んだだけです。

## 免責事項

Glancy は独立したプロジェクトで、Apple や Anthropic とは関係がなく、承認も受けていません。Claude および Claude Code は Anthropic, PBC の商標です。

## ライセンス

[MIT](LICENSE)
