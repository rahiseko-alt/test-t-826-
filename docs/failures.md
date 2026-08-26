# 失敗記録 (docs/failures.md)

> **運用ルール**
> - **追記のみ (Append-Only)。** 過去の記録を書き換えない。
> - **全文を読み込まない。** 照合が必要なときだけ `failure-matcher`（[`prompts/failure-matcher.md`](../prompts/failure-matcher.md)）が参照する。
> - 作業中に発生し**解決した**失敗を、下の形式で末尾に追記する。

## 形式

```text
### [F-YYYYMMDD-NN] 1行で言うと何が起きたか

- **Date**: YYYY-MM-DD
- **Category**: (例: process / build / test / deploy / communication)
- **Trigger/Context**: どういう場面で起きたか
- **Failure**: 実際に何が起きたか（事実のみ）
- **Root Cause**: なぜ起きたか（症状ではなく原因）
- **Guardrail / Prevention**: 次に同じ場面で何をすれば防げるか
```

---

### [F-20260826-01] 初回の質問が「毎回聞かれるのか」と受け取られ、利用者に1往復を追加させた

- **Date**: 2026-08-26
- **Category**: communication
- **Trigger/Context**: 雛形のままのリポジトリでセッションを開始し、`spec.md` が空だったため「今回作るものは何ですか」と尋ねた場面。
- **Failure**: 長い状態報告のあとに質問を置き、その質問が1案件に1回だけのものである旨をどこにも書かなかった。利用者から「これは初回セットアップのみの話か」という確認が返り、本題への回答の前に1往復を消費した。
- **Root Cause**: 頻度の宣言が文言に無かったこと。利用者から見て、確認が今後何回来るのかが未知のまま残っていた。回数が未知の確認は、利用者側に「回数を確かめる確認」を発生させる。
- **Guardrail / Prevention**: 依頼文が無い状態で尋ねるときは [`project-intake` スキル](../.agents/skills/project-intake/SKILL.md) の文言を使う。1行目で「この案件で最初の1回だけ」と述べ、末尾で「確認はその1回で終わり」と述べる。状態報告は1〜2行に抑え、質問より前に長文を置かない。

