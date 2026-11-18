# PR差分からRailsのrequest spec・system specを選ぶ

初版の方針は、Prismで変更された分岐とそこに到達し得るRSpecのexampleを対応付け、PRごとに選択結果を全件実行と照合すること。対象はRailsのrequest specとsystem spec。実行履歴を収集する仕組みは、照合結果を見て追加を判断する。

## GitLabのCrystalballと粒度の違い

GitLabの導入MRでは、Crystalballが記録した「各RSpec exampleが触れたソースファイル」を「ソースファイル → specファイル一覧」に集約した。同じサービスの通常注文とギフト注文が別分岐を通っても、この表では同じキーになる。Sukashiは変更箇所を条件式・then本体・else本体に分け、同じspecファイル内でもexampleごとに候補を持つ。[GitLabの導入MR](https://gitlab.com/gitlab-org/gitlab/-/merge_requests/44968)

## ギフト手数料だけを変更したPR

```ruby
def self.fee(gift)
  if gift
    500   # この金額だけを700に変更
  else
    100
  end
end
```

ギフト用と通常用のactionから、それぞれ `OrderFee.fee(true)` と `OrderFee.fee(false)` を呼ぶアプリを考える。request specの同じファイルに各URLをGETするexampleが1本ずつあり、各actionへの経路は一意とする。system specは画面操作で注文する。

| example | 解析できた経路 | ギフト金額の変更 | 条件式の変更 |
| --- | --- | --- | --- |
| ギフト注文のrequest | ギフトURL → action → 引数true → then | 実行 | 実行 |
| 通常注文のrequest | 通常URL → action → 引数false → else | 省略候補 | 実行 |
| 画面から注文するsystem | ボタン操作後の遷移先が不明 | 実行 | 実行 |

この例では対象3本のうち2本を選ぶ。これは設計上の期待値で、実アプリでの短縮率は後述の照合で測る。Prismから得られるのは分岐の構造とソース範囲であり、表のtrue/falseは呼び出し経路の引数を別に解析して求める。[Prism::IfNode](https://ruby.github.io/prism/rb/Prism/IfNode.html)

## 選択アルゴリズム

入力はPRの比較先commit、PR head、対象specの探索パターン（既定は `spec/{requests,system}/**/*_spec.rb`）。利用側で独自配置を含め、全件ジョブと同じ対象集合を列挙する。「全件」は以下、この集合内のheadに存在する全ファイルを指す。

1. **差分を確定する。** 比較先とheadのmerge-baseをB、実行対象のheadをHとする。`git diff --name-status -z -M B H` で、追加はHのパス、削除はBのパス、変更・移動は両側を記録する。CIもHをcheckoutする。履歴不足でBが得られなければfetchを試し、確定できなければ全件へ戻す。
2. **BとHに依存グラフを作る。** 広めの候補を求める索引の単位はリポジトリ相対パス。辺は「利用ファイル → 定義ファイル」とし、根拠（定数名、route helperなど）と位置を付ける。RubyをPrismでparseし、定数定義とDSL宣言を先に索引化してから、visitorで参照を解決する。再オープンや同名候補は全候補につなぐ。クラス名の単純な末尾一致で一つに決めない。初版は両treeを全走査し、最適化する場合も名前解決は各treeの索引でやり直す。[PrismのRuby API](https://ruby.github.io/prism/rb/docs/ruby_api_md.html)
3. **変更ごとに逆引きする。** 各側の変更パスから逆辺を幅優先でたどり、到達した対象specを集める。訪問済み集合で循環を止める。B側で見つけたspecは移動情報でHの名前に直し、Hで存在を確認する。変更・追加された対象spec自身も必ず加える。各specには少なくとも一つの根拠経路を残す。グラフ構築後の探索は、始点をまとめれば各treeで最大 O(ノード数 + 辺数)。
4. **変更された分岐で絞り、未解決の依存を加える。** 次節の条件を満たす変更だけ、ファイル候補の中からexampleを選ぶ。下表の拡大規則を変更パスごとに適用し、全変更の結果を和集合にする。一つの変更がspecに当たっても、別の未分類の変更を打ち消さない。Hの実行対象を重複排除してパス・ID順に並べる。同じファイルに全体指定とexample指定があればファイル全体を優先する。

### 分岐とexampleの対応を残す

- **変更箇所の識別。** 各版でファイル、クラス／モジュール、メソッド、分岐までのAST上の経路、腕（then / else）をキーにする。行・byte範囲はその版の差分照合と表示用に保存する。BとHでは所有メソッド、条件式、外側の構文と兄弟の順序を比較する。初版で絞るのは、通常の `if 引数 ... else ... end` で、片方の本体で、実行時に評価するリテラル（数値・文字列など）や明示的なレシーバーへの呼び出しの引数だけが変わり、外側の構文・束縛・制御の流れが同じと確認できる場合。たとえば料金の値や通知メソッドに渡す固定文面の変更が該当する。新しいローカル変数の導入、ロード時の定義、制御の移動、分岐の挿入・削除・並べ替え、同名メソッドなどで対応が曖昧ならメソッド候補へ、所有者まで曖昧ならファイル候補へ広げる。条件式を変えた場合は両腕を選ぶ。同じ行に複数の式があっても版ごとのASTで照合する。
- **入力の伝播。** RSpecの静的な `it` ブロックからリテラルのHTTP動詞・経路、controllerのaction、明示した定数レシーバーのメソッド呼び出しまでつなぐ。単純な仮引数にtrue/falseリテラルが渡り、条件評価前の再代入や介入がなく、呼び先が一意の場合だけ片腕に絞る。requestパラメータの文字列をRubyの真偽値と同一視しない。DB値、feature flag、stub、動的送信などを含む経路は両腕が候補。同じexampleから複数回呼べば全経路を合算する。未知の経路は既知の経路と一緒に残す。
- **保存と選択。** 各版で `(版, 分岐キー, 腕) → 到達し得るexampleの集合` と根拠を保持する。未解決のexample・共有フックにはメソッドまたはファイル単位の候補も残す。PRではB/Hの変更された腕から逆引きし、未解決などが理由で残した広い候補も和集合にする。手順3で得た粗い候補は、ここで絞り込み済みの結果に置き換える。あるexampleを外せるのは、変更ごとに両版の関連経路がすべて別の腕に限定できるときだけ。複数変更、複数の呼び出し、共有setupを含む場合にも同じ条件を適用する。比較元のexampleがHのexampleに一意に対応しなければHの対応specを丸ごと選ぶ。
- **RSpecへの引き渡し。** Hで同じ設定のRSpecが列挙したexample IDと定義位置を使い、一意に照合できたexampleだけ `spec/requests/orders_spec.rb[1:2]` 形式で指定する。IDは同じHのplan/runでだけ共有する。動的に生成されたexample、shared examples、フックの帰属、列挙結果に不確かさがあればファイルごと選ぶ。変更・新規specや共通設定に対する全件規則も優先する。

### RailsとRSpecの境界

| 変更・参照 | 初版で選ぶ範囲と理由 |
| --- | --- |
| モデル、サービス、concern | 字句スコープを考慮した定数参照、継承、include、リテラルの `require_relative` を結ぶ。初版で呼び先を一意に決められないインスタンスメソッドは所有ファイルの候補を残す。 |
| HTTPリクエストと画面遷移 | 単純な `resources` とリテラルのHTTP動詞・パス・遷移先から、route helperまたは動詞＋パスとcontrollerファイルを対応付ける。`get orders_path`（request）、`visit orders_path`（system）の両方を結ぶ。初版で対応しないengine、動的URL、ボタン操作などは未解決の利用として記録する。 |
| FactoryBot、shared examples/context | リテラル名で利用元と宣言元を結ぶ。factoryのクラスと静的に分かる親factoryもたどる。衝突は全候補、動的な名前は未解決として扱う。 |
| view、partial、layout | request specもHTMLを検証できる。初版はテンプレート変更で両種を全件。PrismにERB全体は渡さない。ブラウザ用JS/CSSはsystem全件に広げる。assetの内容や配信をrequestでも検査するアプリは両種に広げる。 |
| `config/routes.rb`、initializer、DBスキーマ・migration、Gemfile.lock、共通spec helper、選択器の設定 | アプリ全体の挙動またはspecの探索結果が変わり得るので両種を全件。 |
| ドキュメントだけ | 解析・実行に使うファイルの規則を優先し、それ以外で実行時に読まれないと利用側が明示したパスだけ省略可。変更がすべてこの範囲なら0件を正常とする。 |
| 分類できない変更、parse失敗、依存先を引けない実行コード変更 | 両種を全件。新規ファイルにも適用する。削除されたspecは実行せず、他ファイルから参照されていればBの逆引き結果を使う。移動元specと移動先を対応付けられない場合も、追加されたspecは自身の変更として選ぶ。 |

未解決参照は**利用元にも**記録する。たとえばsystem specが `visit url_for(record)` を使う場合、controllerを変更したPRで別のrequest specが静的にヒットしても、このsystem specを含める。初版では、未解決参照を持つファイルを利用するspecをアプリコード変更時に常時加える。共通フックや自動ロードなどでその利用元を限定できなければ全件に広げる。暗黙のcallbackや別プロセスへの通信を網羅的に認識することは難しく、実アプリでの照合が必要になる。

### ファイル候補まで広げる例

`OrderTotal` を `OrdersController` が利用し、注文一覧のrequest specとsystem specがともに `orders_path` を呼ぶとする。サービスだけを変更したPRの説明は次のようになる（矢印は変更から利用元への逆引き）。

```text
app/services/order_total.rb
  └─ OrderTotal → app/controllers/orders_controller.rb
       ├─ GET orders_path   → spec/requests/orders_spec.rb
       └─ visit orders_path → spec/system/order_history_spec.rb
```

同じPRで `app/views/orders/_total.html.erb` も変更すれば両種を全件実行し、理由にpartialのパスを出す。サービスを移動し、旧定数への依存がheadから消えた場合でも、B側でつながっていた現存specは選択に残る。

## 将来、実行履歴を加えるなら

全件照合で「動的な入力のため、ほぼすべてのexampleで両腕が候補」という事例が多ければ、Bの全件ジョブでRubyの `Coverage.start(branches: true)` を使う案を比較する。実行カウンタの増分を同じ版のソース範囲でPrismの分岐に照合し、観測できた腕とexampleの対応を別に持つ。RubyのCoverageはプロセス全体を計測するので、同時実行中のexampleや別プロセスのRailsサーバーの帰属には計測の分離が必要になる。[Ruby Coverage](https://docs.ruby-lang.org/en/master/Coverage.html)

実行履歴で静的解析の漏れを発見したら候補に加える。履歴だけで未知の腕を除外する運用には、別途、複数回の観測、新規・変更されたexampleの扱い、欠けた計測で静的案に戻す規則と再評価が必要になる。

## CIとの契約

提案するCLIは `bundle exec sukashi plan --base <比較先SHA> --head <PRのSHA>` でJSONを出し、`bundle exec sukashi run --plan <ファイル>` で実行する。planにはB・H、対象集合、モード（subset / full / skip）、選択したexample IDまたはspecパス、対象の分岐と根拠または拡大理由を含める。runはHと対象集合の一致を確認し、選択したID・パスを個別の引数としてRSpecへ渡し、RSpecの終了ステータスを返す。skipは、差分なし、明示的に省略できるパスのみ、または単独のspec削除で現存する利用元がないと確認できた場合に限り、RSpecを起動しない。それ以外で選択結果が空なら全件とする。対象specがあるはずなのに探索できない場合や、planが壊れた場合は既存の全件ジョブへ戻す。全件も実行できなければCIを失敗させる。

## 実装と採否の確認

1. 小さなRailsアプリで上の表を受け入れテストにする。通常注文とギフト注文は同じspecファイルに置き、片腕の整数、条件式、動的入力、双方を呼ぶexample、共有setup、分岐の移動の各変更で期待するID集合を照合する。rename/delete、追加spec、混在差分、parse失敗も含める。ギフト金額を実際に壊す変更を入れ、選択実行がその失敗を検出することを確かめる。
2. 代表アプリの各PRで分岐選択、従来のファイル単位の選択、全件を同じH・設定・seedで比較する。当初のマージ判定は全件ジョブに置く。全件で再現した失敗のexample IDが候補から漏れたら根拠経路を調査する。緑のPRだけでは漏れを測れない。
3. request/system別に、選択example数／全件数、ファイル単位と比べて削れた本数、全件・ファイル単位に広げた理由、解析・RSpec列挙・Rails起動を含む経過時間を記録する。削減本数が実時間の改善につながり、再現した漏れを解消できた条件から利用する。次に対応する構文（case/whenやガード節など）は、実際に広い候補へ戻った頻度を見て選ぶ。
