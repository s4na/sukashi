# テスト選択を検証するRailsアプリ

通常料金100、ギフト料金500を返す小さなアプリです。Rails公式の再現例に倣い、Action ControllerのRailtieで起動し、Rack::TestからHTTPステータスとレスポンス本文を検証します。Sukashiがコミット間のファイル依存をたどれるよう、ルート・controller・料金計算・テンプレートは別ファイルに置いています。[Rails公式のAction Controller再現テンプレート](https://github.com/rails/rails/blob/main/guides/bug_report_templates/action_controller.rb)

リポジトリのGemfileで `bundle install` した後、このディレクトリから通常のランナーで全8件を実行できます。RSpec、MinitestともにsystemテストのドライバはRack::Testです。

```sh
bundle exec rspec
RAILS_ENV=test bundle exec bin/rails test:all
```

リポジトリのルートで `bundle exec ruby test/selection_test.rb` を実行すると、各シナリオがこのアプリを一時Gitリポジトリにコピーし、変更をコミットしてSukashiのCLIを呼びます。ギフト料金の変更では6件を選択し、そのうち5件が失敗します。通常料金しか検査しないRackリクエストも安全側の候補に残り、実行は成功します。

| 変更・条件 | 確認する振る舞い |
| --- | --- |
| 変更なし | 選択はskip。照合用のRSpec 4件・Minitest 4件がすべて成功する |
| ギフト料金のみ／通常料金のみ | 同じファイル内でも反対側だけを通るテストを除外できる。選択したID、実行したID、全件で失敗したIDをそれぞれ検証する |
| 条件式、ルートを含む混在差分 | 全件に広げ、変更後の応答を検査する |
| POSTのパラメーターで分岐 | ギフト・通常の両リクエストを選び、ギフトの応答だけが壊れることを確認する |
| 暗黙描画とpartial | 料金の変更はERB経由でも検出する。partialの文面だけの変更ではreceiptのrequestとsystemテストが失敗する |
| controller callback／Rack middleware | 通常注文の経路からもギフト料金を呼ぶ構成を作り、その経路で発生する失敗を検出する |
| 選択漏れ | 各ランナーのsystemテストをplanから1件ずつ外すと、全件でのみ失敗した正確なIDが返る |
| 実行設定・Gitの境界 | 独自RSpecジョブ、Railsを起動しないMinitestジョブ、比較元欠落、古いplan、テストの移動と追加を検証する |

RSpecのグループ内だけで使うletの変更やMinitestのrunラッパーも同じアプリで検証します。定数の再定義やrefinementなどRuby構文ごとの境界は `test/reachability_test.rb` が担当します。
