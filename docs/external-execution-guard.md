# 外部コードが介入するジョブの分岐除外を止める最小変更案

提案段階。実装・実行再現・Actions確認は未実施。[Issue #16](https://github.com/s4na/sukashi/issues/16) 全体をこの一変更で完了扱いにはしない。

## 最初に作るもの

外部コードの安全性を推測するのではなく、**信頼境界を確認できないジョブでは分岐を根拠とする除外を許可しないゲート**を追加する。初期段階では、外部介入を否定できないジョブを全件へ戻す。ファイル依存への拡大だけでは、外部gemが新しく作った依存を拾えないため不十分である。

ゲートを通過したことと、実行時のメソッドが一度だけ一致したことは同じではない。discovery時点のowner/source_location一致を「安全」の根拠にしない。テストのbefore hook、遅延require、Railtie初期化後の追加登録で後から変わり得るからである。

## 確認できている現状

- [repository.rb:44–61](https://github.com/s4na/sukashi/blob/47be8dbf73a0a2a2454c8c0aad596541b3705ee2/lib/sukashi/repository.rb#L44-L61) の索引はコミット内のRuby/Rackソースに限られる。
- [selection.rb:145–167](https://github.com/s4na/sukashi/blob/47be8dbf73a0a2a2454c8c0aad596541b3705ee2/lib/sukashi/selection.rb#L145-L167) は索引内の定義と引数から到達分岐を計算する。
- [test_helpers.rb](https://github.com/s4na/sukashi/blob/47be8dbf73a0a2a2454c8c0aad596541b3705ee2/lib/sukashi/test_helpers.rb) のチェック対象はテスト側のassertion/HTTP helperであり、料金計算メソッド全体やRailtie登録内容の証明ではない。
- [planner.rb:91–94](https://github.com/s4na/sukashi/blob/47be8dbf73a0a2a2454c8c0aad596541b3705ee2/lib/sukashi/planner.rb#L91-L94) はGemfile/lock/gemspecの変更を全件へ戻す。ただし、既に導入済みのgemによる介入は依存ファイル変更を伴わない。

## 次の小さなPRの範囲

1. discovery結果にジョブ単位の `external_execution_scope` を付ける。値は `unknown` または `intervention_detected` から始める。情報欠落・複数workerの不一致も `unknown`。
2. 変更側の候補メソッドについて、ロード済みなら実際のowner、source_location、super_methodの鎖を調べ、索引と一致しない要素を見つけたら `intervention_detected` にする。定数を調べるためにautoload、const_missing、任意のアプリメソッドを発火させない。未ロードはunknown。
3. RailsのHTTP経路は、外部Railtieのcallback/middlewareを否定できない限りunknown。Railsの内部APIを列挙しただけで安全判定を追加しない。
4. plannerはどちらの値でも、実行コード変更があるジョブを `full` にする。理由は `external execution scope is not proven` または `runtime dispatch differs from indexed source` とする。従来のno-change/明示的docs-onlyのshadow全件確認は維持する。
5. この段階では `safe: true` の設定や「現在ロード済みのgemを全部信頼する」自動生成機能を作らない。#7のenforceを安全だと宣伝しない。

これは削減率を犠牲にして、除外の根拠がないことを明示する初期ガードである。最小PRをさらに絞るなら、2・3の診断情報は後回しにして、unknownゲートと回帰テストから導入する。

## 最小の回帰シナリオ

すべて架空のローカルpath gemを、アプリのGitルートの外側に一時生成する。ネットワーク取得は不要。動作確認はAGENTS.mdどおりGitHub Actionsのみ。

### A/B共通: 絞り込みが本当に失敗を取りこぼす条件にする

各fixtureには、変更分岐に直接到達し、変更前後とも成功する対照exampleを追加する。たとえば変更が500→700なら、その呼び出し結果が正の整数であることを検査する。対照exampleは静的に変更分岐へ到達し、gem経由で変更後だけ失敗するexampleは静的には除外されるように分ける。

1. ガードなしでは、選択IDが空でも全件でもないことと、対照IDを含むがgem経由IDを含まないことを確認する。統合fixtureでは既存の保守的な判定が先に全件へ戻るなら、その挙動を記録し、別のplannerテストで同じID集合を与えてガード前後を検証する。
2. 同じheadを通常の全件モードで実行し、失敗IDがgem経由のexampleだけであることを確認する。
3. ガードありでは、上記のガード固有の理由で全件となり、実行済みIDにgem経由のexampleが含まれ、同じ失敗でCIコマンドが非ゼロ終了することを確認する。空選択や全選択など既存のフォールバックは成功条件としない。

### A. 起動時のメソッドwrap

- アプリの `Fee.amount(gift)` はtrueなら500、falseなら100を返す。
- 通常料金テストは `Fee.amount(false)` を呼ぶ。
- 外部path gemがsingleton classへprependし、受け取ったfalseをtrueに変えてsuperへ渡す。
- baselineでは実際の返値500を検査して成功させる。アプリのtrue側だけ500→700へ変更する。
- 期待: 通常料金という静的な見かけを根拠に除外しない。全件でそのテストの失敗が報告される。
- 別variant: wrapをbefore hookで初めてrequireする。discoveryでメソッド一致を観測できても、unknownゲートから抜けない。

### B. Railtieのmiddleware

- アプリの通常URLは静的にはfalse側だけを返す。
- 外部path gemのRailtieがmiddlewareを登録し、通常URLでも `Fee.amount(true)` を呼ぶ。
- 期待値500と異なる場合にHTTP 409を返す。アプリのtrue側だけ500→700へ変更する。
- 期待: requestテストを残し、全件で409の失敗を検出する。
- gemコードをアプリの索引へ混ぜない。Gemfile/lockの差分による既存のfull fallbackだけで通らないよう、gem導入はbaselineコミットより前に済ませる。

### C. 対照と欠落

- 同じ通常Ruby/Railsアプリから介入gemを外した対照例を用意する。
- 初期unknownゲートでは対照例もfullになることを明示的に検査する。絞り込み維持が確認済みとは書かない。
- discovery証拠欠落、未知のプロファイル、worker間の違いをすべてfullにする。

## Issue #16を完了する前に残る判断

Issueの「従来の単純なRuby/Rails経路で絞り込みを維持する」は、上の初期ガードだけでは満たせない。

再開するには #6 の既知の安全な実行プロファイルが必要である。最低でも、プロファイルが信頼するframework/gemの内容と版、コード読込範囲、hook・Railtie・middleware・遅延ロードの扱い、workerごとの一致条件を固定する。#15の実際の子プロセスのruntime identityはその入力になり得るが、identity一致自体はコードが介入しない証明ではない。

その条件を満たす対照例だけでsubsetを復活させ、A/Bと遅延介入variantがfullのままであることをActionsで確認する。安全プロファイルなしにsource_location一致だけでsubsetを復活させる案は採らない。

## 変更しないこと

外部gemコードの網羅的なPrism解析、Rubyの完全な実行時サンドボックス、任意のRailtieへの安全保証、実行履歴がない分岐の除外は対象外。新たなアプリコードの自動起動手順も追加しない。既存discoveryの範囲で収集できない証拠はunknownとして扱う。
