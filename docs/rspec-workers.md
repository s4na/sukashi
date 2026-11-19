# RSpec の複数プロセスジョブ

RSpec の列挙と実行は、プロセスごとの `rspec-PID.json` に結果を保存します。開始マーカーと完了したレポートを照合し、未完了・壊れたJSON・重複ID・不正な件数・example外エラーは成功扱いしません。既知のinventoryと実行IDの差は従来どおり `inventory_drift` になります。

RSpec の失敗履歴（`example_status_persistence_file_path`）を使う場合、選択実行と失敗 ID の再試行は履歴を読み取り、全件実行だけが結果を書き戻します。`--only-failures` の全件ジョブは、選択実行前に失敗していた example を対象にします。

対応するラッパーには次の契約が必要です。

- Sukashi が追加したRSpecオプションと環境変数を、各RSpec子プロセスに引き継ぐ。
- workerごとに重複しないテストファイルを割り当てる。
- 全workerを待ち合わせ、どれかが失敗・異常終了したらラッパー自身も非ゼロで終了する。
- 各workerは独立したRubyプロセスでRSpecを1回起動する。formatter生成後のforkや、同じPIDでの複数回実行は対象外。

Sukashi は任意のラッパーが本来起動すべきworker数を推測しません。formatterが一度も起動しなかったworkerは開始マーカーを作れないため、ラッパーの終了状態と、既知ならinventoryとの照合が必要です。discoveryから一貫してworkerを省く不正なラッパーの完全性までは保証できません。契約を満たさない既存ジョブは `runner: command` として登録してください。

計測が全く起動しないジョブは `full_only_job` として既存の全件コマンドへ戻ります。一部の計測が始まった後の欠損はopaqueに置き換えて隠さず失敗にします。任意の並列化ツール、リモートworker、実ブラウザ構成の対応を一括して保証する変更ではありません。

GitHub Actions の `test/rspec_workers_test.rb` で、逐次実行、2 workerの列挙・選択・全件実行、未提出・重複・破損レポート、worker異常終了、既知のinventoryからの欠落、opaque fallbackを検証します。MinitestのPID別レポート形式は変更しません。
