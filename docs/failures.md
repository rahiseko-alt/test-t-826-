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

*(記録なし)*
