# sukashi

[English](README.en.md)

PrismでPRの変更分岐からRSpecのexampleとMinitestのテストメソッドを選び、同じコミット・seedで全件実行と照合するRuby CLIです。Railsのrequest spec、system spec、通常のRubyの単体テストを含め、設定した全ジョブが対象です。[選択アルゴリズムの設計](docs/test-selection.md)

## インストール

利用するプロジェクトのGemfileに追加します。

```ruby
gem "sukashi", github: "s4na/sukashi"
```

```sh
bundle install
bundle exec sukashi --version
```

`main`へのpushでテストが通ると、GitHub ActionsがパッチバージョンとテストしたコミットのSHAを `RELEASE` に記録します。`--version`で両方を確認できます。パッチ番号にはこのワークフローの実行番号を使います。複数のpushが重なった場合は最新のコミットを記録するので番号が飛ぶことがあります。利用側の `Gemfile.lock` はこの記録を含むコミットを固定します。新しい版を取り込むには `bundle update sukashi` を実行します。

## PRで使う

Git履歴を取得したリポジトリのルートで、テスト用のDBやブラウザを通常のCIと同じように用意して実行します。

```sh
bundle exec sukashi check --base origin/main --head HEAD --seed 1234 > comparison.json
```

`--base` は比較先のrefまたはSHAです。CIではPR headそのものをcheckoutし、比較先とmerge-baseまでfetchします。GitHub Actionsなら `actions/checkout` の `ref` に `github.event.pull_request.head.sha`、`fetch-depth` に `0`、CLIの `--base` に `github.event.pull_request.base.sha` を指定できます。

選択理由や、変更された腕からたどれるテストIDを確認するには、planを保存して同じcheckoutで実行します。

```sh
bundle exec sukashi plan --base origin/main > plan.json
bundle exec sukashi run --plan plan.json > comparison.json
```

`subset` では選択したIDと全件を順に実行します。`full` は全件を1回実行します。`skip`（差分なし、または明示したドキュメントのみ）でも照合用の全件は実行します。JSONは標準出力、テストのログは標準エラーに出ます。`full_only_failures` は全件でのみ失敗したID、`inventory_drift` は列挙・選択・実行したIDの不一致です。テストの失敗や照合の不一致は終了コード1、設定・起動前の入力エラーは2です。全件との並走中は、ファイル丸ごと選んだ場合の件数（`file_level_count`）と個別ID数を比較できます。時間は列挙・解析の `plan_seconds`、ジョブごとの再列挙の `rediscovery_seconds`（未実施は null）、選択実行の `selected_seconds`、全件の `full_seconds` を分けて記録します。

## 既存のテストジョブを登録する

既定では `spec/` があればRSpec、`test/` があればMinitestを使います。Railsでは `bin/rails test:all` でsystem testを含めます。通常のRubyでは `test/` 以下の `test_*.rb` と `*_test.rb` をロードします。独自のディレクトリ、タグ、分割ジョブがある場合はCIで使う全件コマンドを `.sukashi.yml` に記載します（別名の設定は `--config FILE`）。設定を置いた場合は、そこに列挙したジョブが対象です。

```yaml
jobs:
  specs:
    runner: rspec
    command: [bundle, exec, rspec, spec, integration/spec]
  rails_tests:
    runner: minitest
    command: [bin/rails, "test:all"]
  legacy:
    runner: command
    command: [bundle, exec, rake, legacy_tests]
ignore: ["docs/**/*.md"]
```

コマンドは引数の配列で指定します。RSpecジョブにはRSpec CLIオプションを受け取るコマンドを、MinitestジョブにはMinitestを起動するコマンドを指定します。`command` は既存ジョブをそのまま全件実行し、終了ステータスを確認します。個別IDが得られないジョブは `full_only_job` に記録されます。

### 全件実行に戻すパスを追加する

`full_on` はリポジトリルートからの相対パスに対する glob の配列です。**既定値への追加**であり、置き換えや解除はできません。`full_on: []` でも既定値は残ります。Ruby の変更にも適用し、同じパスが `ignore` に一致しても全件実行を優先します。移動・削除では旧パスも判定します。

```yaml
full_on:
  - "lib/shared/**/*.rb"
  - "lib/tasks/*.rake"
  - "templates/**/*"
ignore:
  - "docs/**/*.md"
```

既定値は `config/**/*`、`db/**/*`、`spec/support/**/*`、`test/support/**/*`、`app/views/**/*`、`app/assets/**/*`、`app/javascript/**/*`、`.github/**/*` と、全階層の `Gemfile`、`Gemfile.lock`、`.rspec`、`.sukashi.yml`、`spec_helper.rb`、`rails_helper.rb`、`test_helper.rb`、`*.gemspec` です。monorepo 内の `packages/sample/Gemfile` や gemspec も全件実行になります。ディレクトリ規則はルート基準なので、入れ子のアプリ設定には `packages/*/config/**/*` などを追加します。

glob は Ruby の `File.fnmatch?`（`FNM_PATHNAME | FNM_DOTMATCH`）で評価します。`*` はパス区切りを越えず、`**/` は任意の深さに一致し、ドットで始まる名前も対象です。先頭の `./` や `/` を付けずに指定してください。

`ignore` が効くのは **非 Ruby ファイルだけ**です。列挙されたテストファイル、既定値または `full_on` に一致するパスは無視できません。それ以外の非 Ruby 変更も `ignore` に一致しなければ全件に戻ります。たとえば `lib/tasks/*.rake` は追加しなくても通常は全件ですが、`full_on` に書けば広い `ignore` より優先できます。`.github/ISSUE_TEMPLATE` だけを省略する設定は現在はサポートしません。安全側の既定値を弱める除外規則は、この設定には設けていません。

### 定数到達性の仮定（opt-in）

`assume: [constant_reachability]` を書くと、「プロジェクトのクラスに到達するには、そのクラス名を定数・文字列・シンボルで書くか、継承関係をたどるしかない」という仮定を置きます。変更ファイルから、参照元・名前を含むリテラルを持つファイル・スーパークラス定義を繰り返したどった閉包の外にあるテストファイルは、`unreachable_change` として除外します。共有 hook が一つあるだけで全テストが候補に残る状況でも、無関係なテストを外せます。

```yaml
assume: [constant_reachability]
```

eval、名前を組み立てる `constantize` / `const_get`、`descendants`、名前と引数を動的に渡す `send`、`inflections` がリポジトリのどこかにある場合や、閉包に共有 hook・`full_on` のパス・グローバル変数への代入・読み込み時の外部呼び出し・gem 名前空間の再オープンが入る場合、Ruby 以外の追跡ファイル（`ignore` に一致するものを除く）にクラス名の形が現れる場合は、仮定を使わず通常の解析に戻ります。テスト間で DB やキャッシュを通じて受け渡される状態、メソッド本体から変数経由で外部へ保存したオブジェクト、gem によるクラスの列挙はこの仮定の外です。閉包にコントローラー・ヘルパー・`config/routes.rb` が入った場合は、HTTP リクエストを発行するテストをまとめて候補に残します。`app/views/` のテンプレートにクラス名の形が現れる場合は、view spec や mailer からの描画も考慮して仮定を使いません。仮定を使ったかどうかと使わなかった理由は plan の `assumptions` に出ます。全件との照合で効果と抜けを確かめてから使ってください。詳細は [selection-safety.md](docs/selection-safety.md) にあります。

設定変更は plan の fingerprint に反映されます。この変更前に作った plan も不一致になり、既存の仕組みで全件実行に戻ります。

## 保存した plan と実行環境

保存した plan の subset / skip を再利用する前に、同じジョブ・seedで列挙をもう一度実行し、実際のRuby子プロセスから得た環境の識別情報を照合します。head・設定が同じでも、環境や列挙したテストIDが違う、古いplanに情報がない、列挙や取得が失敗した場合は、そのジョブを全件実行へ戻します。全件のplanにはこの再列挙を追加しません。

識別情報には有効なGemfile/lockの場所と内容、Ruby、Bundlerの解決済みgem名・版・platform、Sukashiのコード、Bundler/Rubyの起動に関わる環境設定を使います。planの `runtime` に保存するのはハッシュ値と固定の理由だけです。絶対パス、環境変数の値、Gemfileの本文は保存しません。

現在はBundlerとlockfileを確認できる環境が対象です。通常のgemの識別は解決された版を信頼し、インストール済みgemファイルの手動改変までは検出しません。外部ラッパーやRUBYOPTで読み込むファイルの内容も検証対象外です。それらを変更する運用では保存済みplanを再利用せず、全件実行を維持してください。path/git gemは版だけでは内容を確認できないため `opaque` とし、全件に戻します。ただし実行中のSukashi自身はコードをハッシュ化して照合します。外部gemを自動解析したり、起動時パッチの安全性を保証したりする機能ではありません。

同じheadの外部path gem編集を見逃してsubsetを再利用しないための保守的な制約です。理由は `runtime identity unavailable` または `runtime identity changed or unavailable` に出ます。`runner: command` や列挙できないラッパーも全件扱いです。再列挙にはアプリ起動の時間と副作用が加わります。確認後の外部ファイル変更との競合を防ぐため、CIでは実行中の依存と環境を固定してください。

## エラーの診断

入力・設定エラーは終了コード2、予期しない内部エラーはバックトレース付きで3を返します。`--verbose` または `SUKASHI_DEBUG=1` でコマンド・詳細をstderrへ出せます。レポートの `full_status` / `selected_status` は実行失敗と起動失敗を区別します。[診断出力と注意点](docs/diagnostics.md)

## 選択の範囲

初版は、真偽値の仮引数を直接調べるクラスメソッドの `if ... else ... end` で、片側のリテラルなどの変更を識別します。リテラル引数を直接渡すテストや、URLを文字列リテラルで指定したRailsルート → action → クラスメソッドの経路なら反対側だけを通るテストを省けます。controllerの応答を追えるのは単純な `render plain:` までです。アプリで設定したRack middlewareがあるHTTP経路、暗黙の描画、テンプレート・layoutの描画、prepend等によるメソッドの差し替えは未解決として残します。条件の変更、移動・削除などは両版のファイル依存に広げます。動的な呼び出し・共有setupは候補に残し、parse失敗、未分類の変更、比較元の欠落などでは全件実行に戻ります。RSpecグループ内の `let` や `before` は、そのファイルと利用元を候補に残します。controllerの `before_action` は、そのcontrollerや継承先を通る経路に影響します。共通helperの `fixtures :all` や `config.before` のように帰属を限定できないフックがある場合は、全件に戻るため削減できません。全件照合で失敗を再現できることが、選択漏れを検出する条件です。

## 開発と公開 API

動作確認は AGENTS.md に従い GitHub Actions 上でのみ実行します。
Tests ワークフローの `test` は `bundle exec rake test`、
`ruby-lint` は独立した lint bundle で `bundle exec rubocop --lint` を実行します。
Rake の既定タスクも test です。Lint の導入では全体のスタイル変更は行いません。
JSON Schema の検証には CI 専用の Python jsonschema を使います。

`require "sukashi"` は各コンポーネントを明示的に読み込み、コマンドを実行しません。
公開する Ruby API は `Sukashi::CLI.call(argv)` です。引数配列は処理中に変更され、
戻り値は CLI の終了コードです。Planner、Comparison、Repository などは内部実装として扱い、
互換性を保証する API には含めません。

[検証用Railsアプリとシナリオ一覧](fixtures/rails_app/README.md)

## 全件だけで失敗したテストの再確認

既定では従来どおり、テストの失敗や照合不一致で終了コード1になります。
`--retry-full-only` を付けると、`full_only_failures` のIDを同じジョブ・seed・選択用アダプターで1回だけ再実行します。全件での実行順や外部状態までは再現できません。

- `missed_failures`: 再実行でも失敗したID。選択漏れの**疑い**であり、原因確定ではありません。
- `flaky_or_order_dependent`: 再実行ではpassedだったID。flakyと順序依存のどちらかは区別しません。
- `unclassified_full_only_failures`: 再実行しなかった、ID不一致、計測不能、skipなどで判定できなかったID。
- `selected_only_failures`: 選択実行でのみ失敗したID。再実行の分類とは別に残します。
- `retry_ids` / `retry_seconds` / `retry_ok`: 再実行の観測結果。再実行なしはnull。

```sh
bundle exec sukashi check --base origin/main --retry-full-only
```

`--failure-policy missed --retry-full-only` は明示的な緩和です。全件プロセスが通常のテスト失敗コード1で終了し、全件失敗がすべてfull-onlyであり、その全IDが再実行でpassed、再実行プロセスも成功、選択実行成功、ID照合一致の場合だけ成功を許可します。選択実行の失敗、未分類、計測不能、起動不能、シグナル終了、終了コード1以外の失敗は成功にしません。ただし終了コード1にまとめられたテスト外のcleanupエラーまでは判別できません。この緩和を合否判定に使う場合は、その制約を受け入れる必要があります。元の `full_failures` / `full_only_failures` は変更しません。厳密なCIの合否には既定の `strict` を使用してください。再実行には追加のCI時間と副作用があるため、テストが再実行可能な環境でのみ有効にしてください。

## JSONの互換性

plan と comparison report は `version`（メジャー）と `schema_minor`（マイナー）を持ちます。現在は 1.1 です。キー・理由コードの追加はマイナー、既存キーの削除・型や意味の変更はメジャーを更新します。利用側は未知のキー・理由コードを許容してください。既存の理由文字列は残し、集計には `reason_detail.code`、`selected_details`、`excluded_details` を使います。

[JSON契約と理由コード](docs/json-contract.md) · [plan schema](schema/plan.v1.json) · [report schema](schema/report.v1.json)


## 参考元とライセンス

Sukashi は [GitLab 版 Crystalball](https://gitlab.com/gitlab-org/ruby/gems/crystalball) と [GitLab での導入](https://gitlab.com/gitlab-org/gitlab/-/merge_requests/44968) を参考にしています。Crystalball の実行時カバレッジによる対応表とは異なり、現在の Sukashi は Prism による静的解析で候補を選び、全件実行と照合します。Crystalball を gem の依存には含めていません。

Sukashi 自体は [MIT ライセンス](LICENSE)です。GitLab 版 Crystalball のライセンスと著作権表示は [上流の LICENSE](https://gitlab.com/gitlab-org/ruby/gems/crystalball/-/blob/main/LICENSE) を参照してください。今後、上流のコードや文章を取り込む場合は、該当する著作権表示とライセンスを保持し、取り込んだファイルとリビジョンを記録します。

[RSpec の複数プロセスジョブの条件](docs/rspec-workers.md)
