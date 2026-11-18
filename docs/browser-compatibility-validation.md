# Rails 実ブラウザ・別プロセス構成の検証計画

この文書は #19 の実行可能な最小fixture案です。**まだActionsで実行していません。互換性の確認結果ではありません。** 現在のfixtureはRack::Testであり、JavaScript・Chrome・別プロセスのサーバーを検証していません。以下を専用のActionsジョブに載せ、成功・失敗の証拠が揃ってから対応範囲を更新します。

## 四つの能力を分ける

| 能力 | 合格を判定する証拠 |
| --- | --- |
| 起動できる | ChromeとRailsサーバーが起動し、通常ランナーの2例が成功する |
| 列挙できる | Sukashiのdiscoverが2個の安定したIDを返す。ブラウザを起動しない |
| 個別指定できる | 選択アダプターで1個のIDを指定し、実行IDが完全一致する |
| 影響を絞れる | PR差分から対象を選択。未知のクリック・JavaScript経路は除外しない |

「影響を絞れない」は「ブラウザテストを起動できない」ではありません。解析が未知なら対象を残すか全件に戻し、既存コマンドの終了状態を伝えます。Chrome・DB・サーバーの準備は導入先CIの責務です。

## 小さく保つ構成

既存 `fixtures/rails_app` のコピーを一時Gitリポジトリとして使います。既存の8件は変更せず、専用RSpecジョブに下の2例だけを登録します。DBは不要です。Minitestの実ブラウザ対応とDB障害は、この最小PRでは検証済みにしません。

- `embedded`: CapybaraがPumaを起動する。サーバーはテストプロセス内の別スレッド。
- `external`: 独立したPumaプロセスを起動し、Capybaraは `app_host` に接続する。
- どちらもSeleniumのheadless Chromeを使う。Rack::Testへ暗黙にフォールバックしない。
- Railsアプリの変更後はexternalサーバーを必ず再起動する。古いコードに対する成功を新しいheadの成功と扱わない。

現在のGemfile.lockにはSelenium/Pumaがありません。新しい依存を手でlockへ書き足さず、Actionsで解決したlockを保存・レビューします。通常CIに追加する前に、専用実行で使ったRuby・Chrome・chromedriver・依存lock・head SHAを記録します。

## fixtureへの追加

### JavaScript経路

既存 `config/routes.rb` のroutesブロックへ次を追加します。

```ruby
get "/browser_choice", to: "browser_choices#show"
```

`app/controllers/browser_choices_controller.rb`:

```ruby
class BrowserChoicesController < ActionController::Base
  def show
    render html: <<~HTML.html_safe
      <button id="choose">Choose fee</button>
      <script>
        document.querySelector("#choose").addEventListener("click", function () {
          window.location.assign(["", "gift"].join("/"));
        });
      </script>
    HTML
  end
end
```

文字列はfixture内の固定値だけです。利用者入力をHTMLへ渡す例ではありません。クリック後にJavaScriptが遷移先を決めるため、`visit "/browser_choice"` だけを見て通常料金側へ限定してはいけません。

### browser_spec.rb

コピーしたアプリの `spec/browser/browser_spec.rb`:

```ruby
require_relative "../rails_helper"
require "selenium-webdriver"

Capybara.app = Rails.application
Capybara.default_max_wait_time = 3

Capybara.register_driver :sukashi_headless do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--disable-dev-shm-usage")
  options.binary = ENV.fetch("CHROME_BINARY")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

if ENV["BROWSER_SERVER"] == "external"
  Capybara.run_server = false
  Capybara.app_host = ENV.fetch("BROWSER_APP_HOST")
else
  Capybara.run_server = true
  Capybara.server = :puma, { Silent: true }
end

RSpec.describe "browser compatibility", type: :feature do
  before { Capybara.current_driver = :sukashi_headless }
  after { Capybara.reset_sessions! }

  it "follows a JavaScript-selected route" do
    visit "/browser_choice"
    click_button "Choose fee"
    expect(page).to have_text("500")
  end

  it "shows the regular fee" do
    visit "/regular"
    expect(page).to have_text("100")
  end
end
```

専用 `.sukashi.yml`:

```yaml
jobs:
  browser:
    runner: rspec
    command: [bundle, exec, rspec, spec/browser/browser_spec.rb]
```

このbeforeはドライバー選択のための局所hookです。解析器がファイル全体を候補に残しても適切です。「通常料金例を必ず除外できる」を受入条件にしません。

## Actions上の実行手順

専用ジョブはLinux、Ruby 4.0、`contents: read`、有限のtimeoutを使います。以下はActions用のコマンドであり、ローカルでの実行手順ではありません。

1. checkout後、既存Gemfileにテスト用依存を追加し、lockをartifactへ残す。

   ```sh
   bundle add selenium-webdriver puma --group test
   bundle exec ruby -e 'require "selenium-webdriver"; require "puma"; puts RUBY_VERSION'
   "$CHROME_BINARY" --version
   chromedriver --version
   ```

   Chromeとchromedriverはrunnerの実在パス・版を確認し、互換のある組合せを用意します。見つからないときはジョブを失敗にし、skipしません。Selenium Managerのダウンロードを成功と仮定しません。

2. テスト対象を `RUNNER_TEMP` 以下へコピーし、上のoverlayを追加。親プロジェクトのGemfileを `BUNDLE_GEMFILE` に絶対パスで固定します。コピー内の `Gemfile` を不用意に拾わせません。一時Gitリポジトリで初期状態をcommitし、base SHAを保持します。git identityは公開用の架空名・noreplyアドレスとします。

3. external構成では、コピーに `config.ru` を作り、同じheadのRailsを起動します。

   ```ruby
   require_relative "config/environment"
   run Rails.application
   ```

   ```sh
   RAILS_ENV=test bundle exec puma -b tcp://127.0.0.1:43191 config.ru >"$RUNNER_TEMP/server.log" 2>&1 &
   server_pid=$!
   trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT
   # 接続失敗を有限時間で失敗させ、PID生存とHTTP 200の両方を確認する。
   curl --fail --retry 20 --retry-connrefused --retry-delay 1 --retry-max-time 30 http://127.0.0.1:43191/regular
   export BROWSER_SERVER=external BROWSER_APP_HOST=http://127.0.0.1:43191
   ```

   embedded構成では `BROWSER_SERVER=embedded` とし、外部Pumaを起動しません。matrixの各ケースは別runnerで実行し、ポートを共有しません。

4. 通常ランナーの2例成功、discoverでの2 ID取得、1 IDのみの実行を独立に確認します。個別実行はCLIのplan改変で選択可能性を主張せず、既存Runnerのアダプター契約を直接テストします。

   ```ruby
   require "sukashi/runner"
   job = { "runner" => "rspec",
           "command" => %w[bundle exec rspec spec/browser/browser_spec.rb] }
   runner = Sukashi::Runner.new(job, 1234)
   discovery = runner.invoke(discover: true)
   expected = ["./spec/browser/browser_spec.rb[1:1]", "./spec/browser/browser_spec.rb[1:2]"]
   abort "inventory mismatch" unless discovery.ok && discovery.ids == expected
   selected = runner.invoke(ids: [expected.first])
   abort "selection mismatch" unless selected.ok && selected.ids == [expected.first]
   full = runner.invoke
   abort "full run mismatch" unless full.ok && full.ids == expected
   ```

5. `OrderFee.fee` のギフト料金500を700に変更してcommit。externalサーバーを停止・再起動してから `sukashi check --base BASE --seed 1234` を実行します。終了コード1、browserの `full_failures` に `./spec/browser/browser_spec.rb[1:1]` があることを確認します。planがsubsetなら選択IDにもこのIDが必要です。fullでも合格です。数値だけの変更に見えても、未知のブラウザ経路を除外しないことを検証します。

6. Chrome起動失敗とexternalサーバー停止を別ケースとして意図的に起こします。通常ランナーとCLIが非0で終了し、成功報告しないことを確認します。列挙は成功しても実行は失敗し得ます。サーバー停止状態のテストは有限のCapybara待ち時間とActions timeoutで終了させます。選択不能とインフラ障害のJSON分類は #10 の契約に合わせ、追加前には既存の `ok: false` / 非0終了だけを約束します。

## 保存する証拠と完了判定

各構成で通常ランナー結果、discover ID、個別実行ID、plan、comparison、期待する非0終了、環境の版を記録します。スクリーンショット・URL・ログはfixtureの架空データだけに限定します。

以下が揃うまでは #19 を完了扱いにしません。

- embedded / external の通常2例成功と、個別指定1例の一致。
- 料金変更でJavaScript経路の失敗を検出し、そのIDを除外していない。
- Chrome起動不能・externalサーバー停止が成功にならない。
- 実行したhead、lock、ブラウザの版、Actions runへのリンク。
- 選択とブラウザ実行を別ジョブにする場合は、選択された ID・head SHA・設定の識別子を成果物として渡します。実ブラウザのジョブで受け取った選択 ID と実際に走った ID を照合し、同じ head・設定・seed の全件実行を対照にします。ブラウザのジョブが緑というだけでは選択結果が反映されたとはみなしません。
- selectorの狭められる範囲は増やしていないという差分確認。

この最小構成にはDB、MinitestのChromeドライバー、並列worker、remote Selenium grid、異なるホスト上のRailsは含みません。これらを確認せずに「Rails system test全般に対応」とは表現しません。

## 先行するブラウザの検証例

[Henni の Rails E2E](https://github.com/s4na/henni/blob/ecf8e5073450e2032076ca202a86da5e14efde95/spec/rails_e2e_spec.rb) では、RSpec と Minitest の実ブラウザで、クリックから JavaScript の fetch を経由した Rails 呼び出しを検証しています。[先行 CI](https://github.com/s4na/henni/actions/runs/44332577644) は、元の28件と、料金の境界変更で失敗する8件の ID を照合します。Sukashi では同じ発想で、変更後の全件実行が検出した失敗 ID を、選択 ID と実行 ID の両方が含むかを判定します。この先行結果は、Sukashi の選択や別 Rails プロセスの検証結果ではありません。

別プロセス構成で DB を使う場合は、サーバーからも見えるコミット済みのテスト用データを使います。外部サーバーからテスト例内の未コミット行が見えない問題と、テスト選択の問題を分けるためです。上記の DB を使わない fixture はそのままでも構いません。
