#!/usr/bin/env python3
"""紹介用 PDF の元になる HTML を組み立てる。画像は base64 で埋め込む。"""
import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(BASE, "images.json")) as fh:
    IMAGES = json.load(fh)


def img(name, caption=None):
    data = IMAGES[name]
    cap = f'<div class="cap">{caption}</div>' if caption else ""
    return f'<figure><img src="data:image/png;base64,{data}">{cap}</figure>'


def feature_page(title, lead, image, points, note=None):
    items = "\n".join(f"<li>{p}</li>" for p in points)
    note_html = f'<div class="note">{note}</div>' if note else ""
    return f"""
<section class="page">
  <h2>{title}</h2>
  <p class="lead">{lead}</p>
  {img(image)}
  <ul class="points">{items}</ul>
  {note_html}
</section>
"""


PAGES = []

# ---------- 表紙 ----------
PAGES.append(f"""
<section class="page cover">
  <div class="cover-top">
    <div class="badge">macOS 用システムモニタ</div>
    <h1>タスクマネージャー<span class="sub">for Mac</span></h1>
    <p class="tagline">
      Windows のタスクマネージャーに相当する機能を、Apple Silicon 向けに作り直したものです。<br>
      P コア / E コアの区別、ユニファイドメモリ、GPU 使用率、温度、
      そして CPU と GPU それぞれの消費電力を 1 つの画面で確認できます。
    </p>
  </div>
  {img("overview")}
  <div class="cover-facts">
    <div><strong>管理者権限</strong>不要</div>
    <div><strong>外部ライブラリ</strong>なし</div>
    <div><strong>対応</strong> Apple Silicon / macOS 14 以降</div>
  </div>
</section>
""")

# ---------- できること ----------
PAGES.append("""
<section class="page">
  <h2>このアプリでできること</h2>
  <p class="lead">
    Activity Monitor では分かりにくい Apple Silicon 固有の情報を、Windows のタスクマネージャーに
    近い感覚で確認できるようにしたものです。
  </p>
  <div class="grid2">
    <div class="card">
      <h3>P コアと E コアを分けて見る</h3>
      <p>Apple Silicon は高性能コアと高効率コアが混在しています。クラスタ別の使用率と、
      論理コア 1 個ずつのグラフを表示します。</p>
    </div>
    <div class="card">
      <h3>GPU 使用率</h3>
      <p>デバイス使用率に加えて、レンダラ（ピクセル処理）とタイラ（ジオメトリ処理）を
      個別に表示します。ユニファイドメモリから GPU が確保している量も分かります。</p>
    </div>
    <div class="card">
      <h3>温度</h3>
      <p>チップ本体と SSD の温度を、管理者権限なしで表示します。
      <code>powermetrics</code> のような <code>sudo</code> は不要です。</p>
    </div>
    <div class="card">
      <h3>CPU と GPU の消費電力</h3>
      <p>温度では分離できない CPU と GPU の働きを、消費電力で個別に把握できます。
      P コア / E コアの内訳も出ます。</p>
    </div>
    <div class="card">
      <h3>プロセス管理</h3>
      <p>全プロセスの CPU・メモリ・スレッド数・ディスク読み書きを一覧表示。
      検索・並べ替え・終了ができます。</p>
    </div>
    <div class="card">
      <h3>起動項目</h3>
      <p>ログイン時に自動起動するプログラムを一覧し、自分のユーザー領域のものは
      有効・無効を切り替えられます。</p>
    </div>
  </div>
  <div class="note">
    計測処理は UI とは別のスレッド（<code>actor</code>）で動くため、
    表示が固まることはありません。負荷の高いプロセス一覧の収集は、その画面を開いているときだけ動きます。
  </div>
</section>
""")

# ---------- 使い方 ----------
PAGES.append("""
<section class="page">
  <h2>インストールと使い方</h2>

  <h3>1. ビルドする</h3>
  <p>プロジェクトのフォルダで次を実行します。<code>build/タスクマネージャー.app</code> が作られ、そのまま起動します。</p>
  <pre>./build.sh --run</pre>
  <p><code>/Applications</code> に入れる場合は次を実行します。</p>
  <pre>./build.sh --install</pre>
  <p class="small">必要なもの: macOS 14 以降と、Xcode またはコマンドラインツール（<code>xcode-select --install</code>）。
  外部ライブラリの取得は発生しません。</p>

  <h3>2. 画面を切り替える</h3>
  <p>左側のサイドバーで画面を切り替えます。各行には現在値と小さなグラフが出るので、
  サイドバーを見るだけでも全体の状況が分かります。概要画面のカードをクリックしても、
  その画面へ移動できます。</p>

  <h3>3. 更新間隔を変える</h3>
  <p>ウインドウ右上で <strong>0.5 秒 / 1 秒 / 2 秒 / 5 秒</strong> を選べます。
  ノート型でバッテリー駆動中に常用する場合は 2 秒か 5 秒がおすすめです。</p>

  <h3>4. 別の Mac で使う</h3>
  <p>プロジェクトをコピーして、その Mac 上で <code>./build.sh</code> を実行してください。
  ビルド済みの <code>.app</code> をコピーしても動きますが、ネットワーク経由や USB で持ち込むと
  隔離属性が付いて起動を拒まれることがあります。その場合は次で解除できます。</p>
  <pre>xattr -dr com.apple.quarantine "/Applications/タスクマネージャー.app"</pre>

  <h3>キーボードショートカット</h3>
  <table class="kv">
    <tr><td><kbd>⇧⌘T</kbd></td><td>常に最前面に表示を切り替える</td></tr>
    <tr><td><kbd>⌘Q</kbd></td><td>終了する</td></tr>
  </table>
</section>
""")

# ---------- 概要画面 ----------
PAGES.append(feature_page(
    "概要画面",
    "9 枚のカードで、CPU・メモリ・GPU・温度・消費電力・ディスク・ネットワーク・上位プロセス・"
    "ストレージ容量を一度に確認できます。スクロールせずに全体が見えるよう、"
    "ウインドウの高さからカードの高さを自動で計算しています。",
    "overview",
    [
        "各カードには現在値・グラフに加えて、3 つの内訳と補足行が入ります",
        "「CPU 使用率の高いプロセス」カードで、何が負荷をかけているかがすぐ分かります",
        "ストレージカードには外付けドライブの空き容量も表示されます",
        "カードをクリックすると、その詳細画面へ移動します",
    ],
    "ウインドウの幅に応じて 1〜4 列に自動で切り替わります。"
    "極端に小さくした場合だけスクロールに切り替わります。"))

# ---------- CPU ----------
PAGES.append(feature_page(
    "CPU 画面",
    "全体の使用率に加えて、P コア（高性能）と E コア（高効率）のクラスタ別使用率、"
    "論理コア 1 個ずつの推移を表示します。",
    "cpu",
    [
        "ユーザ / システム / アイドルの内訳",
        "クラスタ別の推移を重ねたグラフ（E コアと P コアの働き方の違いが分かります）",
        "論理コアごとの小さなグラフ。E0〜E5、P0〜P3 のように並びます",
        "ロードアベレージ（1 分 / 5 分 / 15 分）、チップ温度、CPU 消費電力",
    ],
    "macOS が返す論理 CPU の並びは「E コアが先、P コアが後」です。"
    "本アプリはこれを実測で確認したうえで正しい順に並べ替えています。"))

# ---------- メモリ ----------
PAGES.append(feature_page(
    "メモリ画面",
    "ユニファイドメモリの内訳を、Activity Monitor と同じ区分で表示します。",
    "memory",
    [
        "アプリメモリ / 確保済み（wired）/ 圧縮 / キャッシュ / 空きの内訳を帯グラフで表示",
        "メモリプレッシャー（正常・警告・危険）はカーネルの判定値を使用",
        "スワップの使用量と確保量",
        "ページイン / ページアウト / スワップイン / スワップアウト / ページフォルトの毎秒の回数",
    ]))

# ---------- GPU ----------
PAGES.append(feature_page(
    "GPU 画面",
    "Apple Silicon の内蔵 GPU の稼働状況を表示します。",
    "gpu",
    [
        "デバイス使用率（GPU 全体）",
        "レンダラ使用率（ピクセル処理）とタイラ使用率（ジオメトリ処理）",
        "GPU が使用中・割り当て済みのメモリ量と、物理メモリに占める割合",
        "GPU の消費電力",
    ],
    "Apple Silicon の GPU はユニファイドメモリを CPU と共有するため、"
    "「GPU 専用メモリ」ではなく共有メモリからの確保量を表示しています。"))

# ---------- 温度・電力 ----------
PAGES.append(feature_page(
    "温度・電力画面",
    "チップ本体と SSD の温度、そして CPU・GPU・メモリそれぞれの消費電力を表示します。"
    "ノート型 Mac ではバッテリーの情報も出ます。",
    "temperature",
    [
        "チップの最高温度・平均温度と、内蔵 SSD の温度",
        "センサーをカテゴリ別に分類して一覧表示（この機種では 38 個）",
        "CPU / GPU / メモリの消費電力を数値と横棒で比較",
        "バッテリー残量・充放電電力・劣化度・サイクル数・温度（ノート型のみ）",
    ],
    "温度も消費電力も管理者権限なしで取得しています。"))

# ---------- ディスク ----------
PAGES.append(feature_page(
    "ディスク画面",
    "読み書きの速度と、物理ディスクごとの状況を表示します。",
    "disk",
    [
        "読み込み・書き込み速度の推移と、毎秒の I/O 回数",
        "物理ディスクごとの読み書き速度（製品名・内蔵/外付け・累計転送量つき）",
        "各ボリュームの使用量と空き容量",
    ],
    "外付けドライブも製品名まで識別して表示します。"))

# ---------- ネットワーク ----------
PAGES.append(feature_page(
    "ネットワーク画面",
    "送受信の速度とパケット数、インターフェースごとの通信量を表示します。",
    "network",
    [
        "受信・送信速度の推移を重ねて表示",
        "毎秒のパケット数と、起動からの累計転送量",
        "インターフェース（Wi-Fi、Ethernet、仮想インターフェースなど）ごとの内訳",
    ]))

# ---------- プロセス ----------
PAGES.append(feature_page(
    "プロセス画面",
    "動作中の全プロセスを一覧表示します。Windows タスクマネージャーの「詳細」タブに相当します。",
    "processes",
    [
        "CPU 使用率・メモリ・スレッド数・CPU 時間・ディスク読み書き・ユーザを表示",
        "名前 / PID / ユーザ で検索、任意の列で並べ替え",
        "選択したプロセスの終了・強制終了（確認ダイアログあり）",
        "列見出しを右クリックすると、列の表示・非表示と並び順を変更できます",
        "Rosetta で動作中のプロセスにはバッジが付きます",
    ],
    "CPU 使用率は「100% = 1 コアを占有」の表記です。10 コアの機種では最大 1000% になります。"))

# ---------- 起動項目 ----------
PAGES.append(feature_page(
    "起動項目画面",
    "ログイン時や OS 起動時に自動で動くプログラムの一覧です。"
    "Windows タスクマネージャーの「スタートアップ」タブに相当します。",
    "startup",
    [
        "ユーザーのログイン項目 / 全ユーザー共通 / システムデーモンに分類して表示",
        "現在動いているものは PID を、異常終了しているものは終了コードを表示",
        "自分のユーザー領域の項目は、スイッチで有効・無効を切り替え可能",
        "右クリックから設定ファイルを Finder で表示できます",
        "このアプリ自身をログイン時に起動する設定もここにあります",
    ],
    "全ユーザー共通の項目とシステムデーモンの変更には管理者権限が必要なため、表示のみとしています。"))

# ---------- メニューバー ----------
PAGES.append(f"""
<section class="page">
  <h2>メニューバー常駐とコンパクト表示</h2>
  <p class="lead">
    ウインドウを開かずに、メニューバーで CPU や温度を見張ることができます。
    ウインドウ自体も小さく畳めるので、作業しながら片隅に置いておけます。
  </p>

  <div class="grid2 tight">
    <div>
      <h3>メニューバー常駐</h3>
      <ul class="points">
        <li>初期状態では CPU 使用率と温度を表示します</li>
        <li>クリックすると CPU・メモリ・GPU・温度の詳しい値が出ます</li>
        <li>表示する項目は「メニューバーに表示する項目」で選べます</li>
        <li>常駐している間は、ウインドウを閉じてもアプリは終了しません</li>
      </ul>
      <h3>常に最前面</h3>
      <ul class="points">
        <li><kbd>⇧⌘T</kbd>、または「モニター」メニューとメニューバーから切り替えます</li>
        <li>他のアプリを操作していても、ウインドウが隠れなくなります</li>
        <li>設定は次回起動時も保持されます</li>
      </ul>
    </div>
    <div>
      {img("compact", "ウインドウを 660×660 まで縮めたところ。2 列に折り返して 9 枚すべてが収まります。最小 480×320 まで縮小できます。")}
    </div>
  </div>

  <div class="note">
    幅を狭めると、各画面のタイルは自動的に折り返します。
    サイドバーはウインドウ左上のボタンで隠せるので、さらに小さくできます。
  </div>
</section>
""")

# ---------- 温度の技術解説 ----------
PAGES.append("""
<section class="page">
  <h2>温度センサーについて（実測で特定）</h2>
  <p class="lead">
    M4 Mac mini が公開するセンサー名は <code>PMU tdie1〜14</code> のような汎用名で、
    CPU / GPU と明示された名前がありません。そこで実機で
    <strong>CPU 全コア負荷 30 秒</strong>と <strong>GPU 負荷 30 秒</strong>をかけ、
    各センサーの上昇幅を測って分類しました。
  </p>

  <table class="data">
    <thead><tr><th>センサー</th><th>CPU 負荷での上昇</th><th>GPU 負荷での上昇</th><th>判定</th></tr></thead>
    <tbody>
      <tr><td><code>PMU tdie1</code></td><td class="hot">+14.7℃</td><td>+7.0℃</td><td>SoC ダイ（CPU 寄り）</td></tr>
      <tr><td><code>PMU tdie6</code></td><td>+13.1℃</td><td>+9.3℃</td><td>SoC ダイ</td></tr>
      <tr><td><code>PMU tdie2</code></td><td>+7.7℃</td><td class="hot">+10.2℃</td><td>SoC ダイ（GPU 寄り）</td></tr>
      <tr><td><code>PMU tdev1〜8</code></td><td>+2〜4℃</td><td>+1〜4℃</td><td>電源部</td></tr>
      <tr><td><code>PMU2 tdie*</code></td><td>+1℃ 前後</td><td>+1℃ 前後</td><td>別ドメイン（基板側）</td></tr>
      <tr><td><code>NAND CH0 temp</code></td><td>+1.0℃</td><td class="cold">+0.0℃</td><td><strong>SSD</strong></td></tr>
      <tr><td><code>PMU tcal</code></td><td class="cold">+0.0℃</td><td class="cold">+0.0℃</td><td>校正用 → 一覧から除外</td></tr>
    </tbody>
  </table>

  <h3>結論</h3>
  <ul class="points">
    <li><strong>SSD 温度は独立して取得できます。</strong>CPU / GPU 負荷では動きません。</li>
    <li><strong>CPU と GPU の温度は分離できません。</strong>Apple Silicon は CPU と GPU が同じダイに載っており、
      <code>tdie</code> センサーはダイ上に分散しているだけで、どちらの負荷でも上昇します。
      これは実装の制約ではなく物理的な構成によるものです。</li>
    <li>そのため「SoC ダイ（CPU・GPU 共通）」としてまとめ、
      <strong>どちらが働いているかは消費電力で判別</strong>できるようにしています。</li>
  </ul>

  <div class="note">
    M1 / M2 のノート型は <code>pACC MTR Temp Sensor</code>（P コア）、<code>eACC</code>（E コア）、
    <code>GPU MTR</code> という名前でセンサーを公開するため、その機種では CPU / GPU 別に表示されます。
    分類はセンサー名から自動判定します。
  </div>
</section>
""")

# ---------- 電力・制限 ----------
PAGES.append("""
<section class="page">
  <h2>消費電力の取得と、既知の制限</h2>

  <h3>消費電力</h3>
  <p><code>IOReport</code> の "Energy Model" グループから、管理者権限なしでブロック別の消費電力を取得しています。
  温度と違い、CPU と GPU は個別に計測されています。175 チャンネルの購読で 1 回あたり約 2 ミリ秒と軽量です。</p>
  <table class="kv wide">
    <tr><td>GPU</td><td>5.92 W</td></tr>
    <tr><td>CPU</td><td>2.08 W（P コア 1.31 W / E コア 1.21 W）</td></tr>
    <tr><td>DRAM</td><td>1.12 W</td></tr>
  </table>
  <p class="small">M4 Mac mini でのアイドル寄りの取得例</p>

  <h3>2 台の Mac での違い</h3>
  <table class="data">
    <thead><tr><th></th><th>M4 Mac mini</th><th>M1 MacBook Air</th></tr></thead>
    <tbody>
      <tr><td>コア構成</td><td>4P + 6E（自動検出）</td><td>4P + 4E（自動検出）</td></tr>
      <tr><td>GPU</td><td>10 コア</td><td>7 または 8 コア</td></tr>
      <tr><td>温度センサー</td><td><code>PMU tdie</code> 系（ダイ全体）</td><td><code>pACC</code>/<code>eACC</code>/<code>GPU MTR</code>（CPU・GPU 個別）</td></tr>
      <tr><td>バッテリー画面</td><td>非表示（バッテリー無し）</td><td>残量・充放電電力・劣化・温度を表示</td></tr>
    </tbody>
  </table>

  <h3>既知の制限</h3>
  <ul class="points">
    <li><strong>CPU と GPU の温度は分離できません。</strong>同一ダイのためで、消費電力で判別してください。</li>
    <li><strong>外付けドライブの温度は取得できません。</strong>macOS の USB マスストレージドライバが
      SAT パススルーに対応しておらず、ドライブ内のセンサーに到達できません
      （macOS 自身も「SMART: 非対応」と報告します）。代わりに読み書き速度を表示しています。</li>
    <li><strong>ファン回転数は表示しません。</strong>M4 Mac mini では IORegistry に公開されていませんでした。</li>
    <li><strong><code>kernel_task</code>（PID 0）は一覧に出ません。</strong>CPU 時間を取得する手段がなく、
      0% と表示すると誤解を招くため除外しています。</li>
    <li><strong>プロセスの終了は自分が所有するものだけ可能です。</strong></li>
    <li><strong>温度と電力は非公開 API を使っています。</strong>将来の macOS で取得できなくなる可能性があります。
      その場合は該当の表示だけが自動的に無効化され、他の機能は通常どおり動作します。</li>
  </ul>

  <h3>本アプリ自身の負荷</h3>
  <table class="kv wide">
    <tr><td>概要画面（更新間隔 1 秒）</td><td>1 コアに対して約 8%</td></tr>
    <tr><td>グラフ画面（更新間隔 1 秒）</td><td>約 4〜6%</td></tr>
    <tr><td>プロセス画面（更新間隔 5 秒）</td><td>約 3%</td></tr>
  </table>
  <p class="small">10 コアの M4 全体で見ると 1% 未満です。</p>
</section>
""")

HTML = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<title>タスクマネージャー for Mac — 使い方と機能紹介</title>
<style>
  @page { size: A4; margin: 14mm 13mm; }
  * { box-sizing: border-box; }
  body {
    font-family: "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif;
    color: #1c1c1e; font-size: 10pt; line-height: 1.7; margin: 0;
    -webkit-print-color-adjust: exact; print-color-adjust: exact;
  }
  .page { page-break-after: always; }
  .page:last-child { page-break-after: auto; }

  h1 { font-size: 30pt; margin: 0 0 4pt; letter-spacing: -0.5pt; }
  h1 .sub { font-size: 15pt; font-weight: 400; color: #6b6b70; margin-left: 10pt; letter-spacing: 0; }
  h2 { font-size: 17pt; margin: 0 0 8pt; padding-bottom: 5pt; border-bottom: 2px solid #1c1c1e; }
  h3 { font-size: 11.5pt; margin: 14pt 0 4pt; color: #0a5bd3; }
  p { margin: 0 0 7pt; }
  .lead { color: #3a3a3e; margin-bottom: 10pt; }
  .small { font-size: 8.5pt; color: #6b6b70; }

  figure { margin: 0 0 8pt; }
  img { width: 100%; border: 1px solid #d5d5da; border-radius: 5px; display: block; }
  .cap { font-size: 8.5pt; color: #6b6b70; margin-top: 4pt; text-align: center; }

  ul.points { margin: 6pt 0; padding-left: 15pt; }
  ul.points li { margin-bottom: 3pt; }

  .note {
    background: #f2f5fa; border-left: 3px solid #0a5bd3; padding: 7pt 10pt;
    font-size: 9pt; margin-top: 9pt; border-radius: 0 4px 4px 0;
  }

  pre {
    background: #1c1c1e; color: #f2f2f5; padding: 8pt 11pt; border-radius: 5px;
    font-family: "SF Mono", Menlo, monospace; font-size: 9pt; margin: 5pt 0 9pt;
    white-space: pre-wrap; word-break: break-all;
  }
  code {
    font-family: "SF Mono", Menlo, monospace; font-size: 0.88em;
    background: #eeeef2; padding: 1pt 4pt; border-radius: 3px;
  }
  pre code { background: none; padding: 0; }
  kbd {
    font-family: "SF Mono", Menlo, monospace; font-size: 0.85em; background: #fff;
    border: 1px solid #c5c5cc; border-bottom-width: 2px; border-radius: 4px; padding: 1pt 5pt;
  }

  table { border-collapse: collapse; width: 100%; margin: 6pt 0 9pt; font-size: 9pt; }
  table.data th {
    background: #1c1c1e; color: #fff; text-align: left; padding: 5pt 8pt; font-weight: 600;
  }
  table.data td { border-bottom: 1px solid #e2e2e7; padding: 4.5pt 8pt; }
  table.data tr:nth-child(even) td { background: #fafafc; }
  .hot { color: #c0392b; font-weight: 700; }
  .cold { color: #1f7a4d; font-weight: 700; }
  table.kv td { padding: 3.5pt 8pt; border-bottom: 1px solid #e8e8ed; }
  table.kv td:first-child { width: 88pt; color: #6b6b70; }
  table.kv.wide td:first-child { width: 190pt; color: #1c1c1e; font-weight: 600; }

  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 9pt; margin: 9pt 0; }
  .grid2.tight { gap: 14pt; align-items: start; }
  .card { background: #f7f7fa; border: 1px solid #e6e6eb; border-radius: 6px; padding: 9pt 11pt; }
  .card h3 { margin: 0 0 3pt; font-size: 10.5pt; color: #1c1c1e; }
  .card p { margin: 0; font-size: 9pt; color: #46464b; }

  /* 表紙 */
  .cover { display: flex; flex-direction: column; height: 100%; }
  .cover-top { margin-bottom: 12pt; }
  .badge {
    display: inline-block; background: #0a5bd3; color: #fff; font-size: 8.5pt;
    padding: 3pt 9pt; border-radius: 20px; margin-bottom: 9pt; font-weight: 600;
  }
  .tagline { color: #46464b; font-size: 10.5pt; margin-top: 7pt; }
  .cover-facts {
    display: flex; gap: 10pt; margin-top: 12pt;
  }
  .cover-facts div {
    flex: 1; background: #f7f7fa; border: 1px solid #e6e6eb; border-radius: 6px;
    padding: 8pt; text-align: center; font-size: 9pt;
  }
  .cover-facts strong { display: block; color: #0a5bd3; font-size: 10pt; }
</style></head><body>
""" + "\n".join(PAGES) + "</body></html>"

out = os.path.join(BASE, "guide.html")
with open(out, "w") as fh:
    fh.write(HTML)
print("HTML を作成しました:", out, f"({len(HTML)/1048576:.1f} MB)")
