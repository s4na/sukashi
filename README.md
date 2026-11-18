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

## 選択の範囲

初版は、真偽値の仮引数を直接調べるクラスメソッドの `if ... else ... end` で、片側のリテラルなどの変更を識別します。リテラル引数を直接渡すテストや、URLを文字列リテラルで指定したRailsルート → action → クラスメソッドの経路なら反対側だけを通るテストを省けます。controllerの応答を追えるのは単純な `render plain:` までです。アプリで設定したRack middlewareがあるHTTP経路、暗黙の描画、テンプレート・layoutの描画、prepend等によるメソッドの差し替えは未解決として残します。条件の変更、移動・削除などは両版のファイル依存に広げます。動的な呼び出し・共有setupは候補に残し、parse失敗、未分類の変更、比較元の欠落などでは全件実行に戻ります。RSpecグループ内の `let` や `before` は、そのファイルと利用元を候補に残します。controllerの `before_action` は、そのcontrollerや継承先を通る経路に影響します。共通helperの `fixtures :all` や `config.before` のように帰属を限定できないフックがある場合は、全件に戻るため削減できません。全件照合で失敗を再現できることが、選択漏れを検出する条件です。

開発時の検証は `bundle install` の後、`bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require_relative f }'` で実行します。

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


## 参考元とライセンス

Sukashi は [GitLab 版 Crystalball](https://gitlab.com/gitlab-org/ruby/gems/crystalball) と [GitLab での導入](https://gitlab.com/gitlab-org/gitlab/-/merge_requests/44968) を参考にしています。Crystalball の実行時カバレッジによる対応表とは異なり、現在の Sukashi は Prism による静的解析で候補を選び、全件実行と照合します。Crystalball を gem の依存には含めていません。

Sukashi 自体は [MIT ライセンス](LICENSE)です。GitLab 版 Crystalball のライセンスと著作権表示は [上流の LICENSE](https://gitlab.com/gitlab-org/ruby/gems/crystalball/-/blob/main/LICENSE) を参照してください。今後、上流のコードや文章を取り込む場合は、該当する著作権表示とライセンスを保持し、取り込んだファイルとリビジョンを記録します。
