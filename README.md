# sukashi

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

`subset` では選択したIDと全件を順に実行します。`full` は全件を1回実行します。`skip`（差分なし、または明示したドキュメントのみ）でも照合用の全件は実行します。JSONは標準出力、テストのログは標準エラーに出ます。`full_only_failures` は全件でのみ失敗したID、`inventory_drift` は列挙・選択・実行したIDの不一致です。テストの失敗や照合の不一致は終了コード1、設定・起動前の入力エラーは2です。全件との並走中は、ファイル丸ごと選んだ場合の件数（`file_level_count`）と個別ID数を比較できます。時間は列挙・解析の `plan_seconds`、選択実行の `selected_seconds`、全件の `full_seconds` を分けて記録します。

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

設定変更は plan の fingerprint に反映されます。この変更前に作った plan も不一致になり、既存の仕組みで全件実行に戻ります。

## 選択の範囲

初版は、真偽値の仮引数を直接調べるクラスメソッドの `if ... else ... end` で、片側のリテラルなどの変更を識別します。リテラル引数を直接渡すテストや、URLを文字列リテラルで指定したRailsルート → action → クラスメソッドの経路なら反対側だけを通るテストを省けます。controllerの応答を追えるのは単純な `render plain:` までです。アプリで設定したRack middlewareがあるHTTP経路、暗黙の描画、テンプレート・layoutの描画、prepend等によるメソッドの差し替えは未解決として残します。条件の変更、移動・削除などは両版のファイル依存に広げます。動的な呼び出し・共有setupは候補に残し、parse失敗、未分類の変更、比較元の欠落などでは全件実行に戻ります。RSpecグループ内の `let` や `before` は、そのファイルと利用元を候補に残します。controllerの `before_action` は、そのcontrollerや継承先を通る経路に影響します。共通helperの `fixtures :all` や `config.before` のように帰属を限定できないフックがある場合は、全件に戻るため削減できません。全件照合で失敗を再現できることが、選択漏れを検出する条件です。

開発時の検証は `bundle install` の後、`bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require_relative f }'` で実行します。

[検証用Railsアプリとシナリオ一覧](fixtures/rails_app/README.md)
