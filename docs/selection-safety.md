# テストを省略できる前提と shadow 運用

この文書は、現在の実装がテストを省略するときの前提と、次に解析範囲を広げるために集める証拠をまとめる。Ruby 全体の安全性を証明するものではない。新しい構文への対応や全件実行の停止は、この文書の追加では行わない。

## 現在の境界

「危険な構文が見つからなかった」だけでは省略の根拠にしない。既知の形として解析でき、必要な対応が両版で確認できた場合だけ候補から外す。現在の `Reachability#trace` は未対応ノードを unknown にする一方、`SourceIndex` のファイル走査には動的な仕組みを個別に検出する処理も残る。**ファイル全体の allowlist 化は未実装**であり、下表の回帰テストだけで動的な Ruby を網羅できたとは判断しない。

以下のテスト名は [reachability_test.rb](../test/reachability_test.rb) と [selection_test.rb](../test/selection_test.rb) にある。前提を変えるときは、対応する実装と回帰テストを同じ変更で更新する。

| 省略に必要な前提 | 現在の確認箇所・崩れたときの扱い | 回帰テスト |
| --- | --- | --- |
| 差分・設定・実行対象が同じ版を指す | `Planner#prepare` と `Comparison#run`。比較元が取れない、checkout や plan が合わない場合は全件 | `test_full_command_runs_on_stale_plan_and_missing_history` |
| 分岐の形と分岐外のソースが変わらない | `BranchDiff.template/between`。定義が一意の `def self.m(arg)`、必須引数が一つ、本体がその引数を条件とする `if ... else ... end` 一文。腕の直接のリテラル、または明示 receiver の呼び出し引数にある対応リテラルだけをマスクし、残るファイル全体を比較する。成立しなければファイル依存へ広げる | `test_same_line_changes_are_assigned_to_individual_arms`、`test_predicate_change_runs_all_tests` |
| 到達する腕が両版で判明し、変更された腕を通らない | `Reachability#trace/follow` と `Planner#select`。真偽値が不明、再帰、未知の呼び出し・ノードなどは候補に残す。複数呼び出しの証拠は合算する | `test_unknown_input_and_multiple_calls`、`test_request_parameter_keeps_both_possible_paths` |
| 呼び先の解決が一意で、差し替えがない | `SourceIndex` と `Reachability#follow`。再定義、定数別名、refinement、prepend などを検出した経路は unknown | `test_explicit_receiver_redefinition_outside_class_body`、`test_lexical_receiver_can_be_a_constant_alias`、`test_refinements_keep_calls_with_lexically_changed_dispatch`、`test_wrapped_class_method_is_not_a_proven_branch` |
| HTTP 経路が解析可能で、応答までの介入がない | ルートが一意に解決でき、action が単純な `render plain:` で終わる場合に限定。callback、middleware、helper の上書き、未解析の描画は候補に残す | `test_callback_invokes_the_other_arm`、`test_middleware_invokes_the_other_arm`、`test_inherited_http_helper_can_reach_the_other_arm`、`test_unindexed_views_keep_requests_even_if_the_action_calls_the_other_arm` |
| setup・登録 DSL・テスト実行プロトコルが省略判定を迂回しない | 共有 hook とその利用元は候補に残す。グループ内の局所的な変更は、外側のバイト列が不変のときだけ範囲を限定する | `test_group_registration_dsl_and_alternate_configuration_hooks`、`test_teardown_lifecycle_keeps_tests_in_derived_classes`、`test_inherited_minitest_run_override_keeps_the_wrapped_test`、`test_edit_to_group_local_let_selects_only_that_spec_file` |
| 共有設定・未分類の変更を省略しない | `Planner#prepare/shared?`。view、routes、依存設定などは全件。非 Ruby は明示的な ignore に一致し、共有扱いでもテストでもない場合だけ除ける。移動は旧・新パスを両方見る | `test_partial_change_reaches_request_and_browser`、`test_route_edit_takes_precedence_over_a_narrow_branch_edit`、`test_rename_mixed_with_a_new_test_keeps_the_new_test` |
| 実際に実行したテストと選択 ID が対応する | ランナーの列挙結果を利用し、`Comparison#compare` で実行 ID と失敗 ID を全件実行と照合。空の選択は全件に戻す | `test_branch_selection_and_comparison`、`test_custom_job_preserves_directory_and_selects_individual_examples` |

これは回帰テストとの対応表であり、各行の全条件を網羅する証明ではない。既知の未対応構文は安全側に戻す。ただし未知の動的な介入を検出し切れているとは限らないため、全件照合を続ける。

## 定数到達性の仮定（opt-in）

`assume: [constant_reachability]` は上表とは別の、明示的に受け入れる仮定です（[#36](https://github.com/s4na/sukashi/issues/36)）。共有 hook・`let`・未解析の呼び出しで全テストが候補に残る状況で、変更から到達しえないテストファイルだけを外します。実装は [constant_reachability.rb](../lib/sukashi/constant_reachability.rb)、回帰テストは [constant_reachability_test.rb](../test/constant_reachability_test.rb) と `test_constant_reachability_assumption_narrows_a_global_hook`。

**仮定**: プロジェクトのクラスに到達するには、その名前を定数・文字列・シンボルで書くか、継承関係をたどる必要がある。テスト間で共有される状態を通じて変更の影響が伝わることはない。

**閉包 U**: 変更ファイル（各版で旧・新パス）から始め、次を追加し続ける。

- U のファイルを定数・factory・shared example・ルート・`require_relative` で参照するファイル。
- U で代入した定数（`Fee = Struct.new(:amount)` など）を読むファイル。同じ短い定数名を異なる名前空間で使う場合も候補に含む。
- U で代入する定数と、定義するクラス・モジュールの名前の形（CamelCase、snake_case、末尾語の複数形を含む接頭辞、不規則複数形）を文字列・シンボルリテラルに含む Ruby ファイル。テストファイルが定義するクラスは対象外。
- U のクラスのスーパークラスを定義するファイル（STI や `find` で派生クラスが返るため）。`self.abstract_class = true` を宣言するクラスは除く。
- U にコントローラー・ビューヘルパー（`app/controllers/`・`app/helpers/` 配下か、名前が `Controller`・`Helper` で終わるクラス・モジュール）か `config/routes.rb` が入ったら、HTTP リクエスト・`visit` を発行するすべてのファイル。リクエストはルーティングを経てコントローラーに届き、テンプレートはヘルパーをメソッド名で呼ぶため、名前を書かずに到達する。URL の解決可否にかかわらずまとめて加える。

旧版の U にも新版の U にも入らないテストファイルの例を `unreachable_change` で除外する。変更されたテスト、カスタムプロトコルは従来どおり先に選ぶ。U の中のテストは従来の解析で判定する。

**仮定を使わない条件**（各版で一つでも該当すれば、その PR では除外しない）:

- リポジトリのどこかに eval・計算された定数名の代入、名前を組み立てる `constantize` / `const_get` 系、`descendants` / `subclasses` / `each_object` / `const_missing`、メソッド名を計算して引数も渡す `send` 系、計算した名前の `method` 系、`inflections` がある。
- U に共有 hook（テスト以外の hook と `config.before` などのスコープ外 hook）、`full_on` に一致するパス（`config/routes.rb` を除く）、グローバル変数への代入がある。HTTP を発行するファイルが support など `full_on` 側にあれば、ここで使わない側に倒れる。
- U のファイルが読み込み時（メソッド・lambda・遅延ブロックの外）に、U で定義していない定数や動的な receiver のメソッドを呼ぶ。`RSpec`・`FactoryBot`・`Struct` など状態を保持しない一部の定数は除く。
- U がコアや Gemfile.lock の gem 名と同じ最上位名前空間を再オープンする。
- `ignore` に一致しない Ruby 以外の追跡ファイル（fixture YAML、アセット、ドキュメントなど）に名前の形が現れる。`app/views/` のテンプレートは view spec や mailer からも描画されるため、名前の形が現れれば `ignore` にかかわらず仮定を使わない。

plan の `assumptions.constant_reachability` に、仮定を使ったか（`applied`）と、使わなかった場合の理由（`reason`、例: `head: reflective lookup in app/models/x.rb`）を出す。shadow 計測では、この理由の分布で仮定が効かない原因を集計する。

**仮定の外にある抜け道**: メソッド本体が変数経由の receiver（キャッシュ、レジストリ）へ U のオブジェクトを保存し、別のテストが読む場合。DB・ファイル・プロセス内状態を通じたテスト間の受け渡し。gem がクラスを登録・列挙する場合。名前のリテラルを組み立てて別の手段で解決する場合。これらは静的には閉じられないため、opt-in とし、shadow の全件照合で `full_only_failures` を確認する。

## ファイル単位の allowlist へ進める手順

1. 抜け道が見つかったら、最初に上表のどの前提が崩れたかと最小の回帰例を記録する。影響範囲が確定するまで絞り込みを増やさない。
2. ファイルを「既知の構文・解決可能な束縛だけで構成される」「未対応を含む」に分類する案を、shadow データで頻出した形から検討する。未対応は既存の候補保持または全件への拡大より狭くしない。
3. 新しい形を許可する PR は、除外できる正常例だけでなく、前提を一つ崩した反例、B/H の両版、既存経路との組み合わせを示す。既存の検出処理を削るなら、それを置き換える肯定的な確認を先に示す。
4. 未対応構文を許可する条件と回帰テストが定まるまでは、denylist の追加だけを「網羅できた」という根拠にしない。

この手順は今後の変更の受け入れ条件。現状の解析器を全面的に書き換える計画や、特定の構文を先に対応すると決めるものではない。

## 代表アプリで集める証拠

1〜2個の代表アプリで、既存の全件 CI をマージ判定に残したまま実施する。アプリ名やデータは公開レポートでは架空の識別子に置き換える。テスト、CLI、サンプルの動作確認は GitHub Actions で実行する。

- PR の head、merge-base、設定 fingerprint、seed、Ruby・ランナー・Sukashi の版、ジョブ名を固定して記録する。DB、外部サービス、キャッシュなど比較条件も揃える。
- 同じ head と設定で `plan` と `run` の JSON を保存する。plan の `jobs.*.reason` と `mode`、比較結果の `full_only_failures` と `inventory_drift` を保持する。理由の機械可読コードは別の拡張であり、現在の自由文を安定した API とみなさない。
- 実行した PR・ジョブを分母にし、full の理由別件数と subset の割合を集計する。PR 単位では「一つでも subset」「全ジョブ full」を別に数え、ジョブ数の多いアプリに引きずられないようにする。失敗・起動不能の試行を削減実績から除外しても、件数と理由は残す。
- `plan_seconds` は plan 全体、再列挙の `rediscovery_seconds`、`selected_seconds`、`full_seconds` はジョブ単位。複数ジョブで plan 時間を重複加算しない。選択実行時間の差だけでなく、列挙・解析の費用を含む推定純削減を示す。shadow は全件も実行するため、実際の CI 時間を短縮したとは報告しない。
- `file_level_count` は選択されたテストをファイル単位に広げた件数であり、ファイル単位実行の実測時間ではない。時間を比較するなら同じ環境の別ジョブで測定する。
- request、system、単体テストを含むジョブごとに件数・時間・照合結果を確認する。全件で再現しない失敗や外部状態の差は、この照合だけでは選択漏れを検出できない。

### 次に精密化する対象の選び方

全件だけでの失敗、ID のずれ、起動不能があれば先に原因を調べ、再現例と安全側への戻し方を残す。未解決の選択漏れがある間は、その範囲の精密化を進めない。

問題がなければ、理由別の発生頻度、対象ジョブの全件時間、解析コスト、肯定的な安全条件を記述できるかを並べて候補を比較する。頻度だけで構文を追加しない。データが少ない場合は「効果未確認」とし、全件実行を維持する。採用候補には、観測期間・試行数・比較条件・期待する削減・残る前提を添えてレビューする。

関連: [選択アルゴリズムと照合手順](test-selection.md)、[#6](https://github.com/s4na/sukashi/issues/6)。
