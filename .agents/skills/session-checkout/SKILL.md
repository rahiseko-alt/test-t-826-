---
name: session-checkout
description: >-
  Use this skill at the end of a working session or when completing a task.
  Performs the Out-check protocol: updates docs/handoff.md, records failures,
  commits, pushes, and MERGES to the default branch. Checkout is not complete until a
  brand-new session starting from a fresh container would lose nothing.
---

# Session Check-out Skill (セッション終了プロトコル)

セッション終了時 (`Out`) に実行する手順。目的は1つだけ——**次のセッションが何も失わないこと**。

> **なぜマージまでやるか**: 次セッションは**別コンテナ**で **既定ブランチを新規クローン**して始まる。
> 作業ブランチにプッシュしただけでは引き継ぎが既定ブランチに乗らず、**次セッションには一切届かない**。

> **ここで門②（ずれ検知）は回さない。** 門②は「変更が出来上がった直後・同じセッションの中」で回す
> （`AGENTS.md` 冒頭）。
> 終了時に検知しても、直すのはコンテキストを持たない次のAIになり精度が落ちる。

## 手順 (Workflow)

1. **記録の更新**:
   - [`docs/handoff.md`](../../../docs/handoff.md) を更新する（今回やったこと / 現在の状態 / 次回やること）。**次セッションはこれだけを頼りに別コンテナで再開する**前提で自己完結させる。
   - 恒久的な設計が決まった場合は [`docs/design.md`](../../../docs/design.md) に反映する。
   - 失敗が発生・解決していれば [`docs/failures.md`](../../../docs/failures.md) に追記する (Append-Only)。

2. **コミット & プッシュ & マージ — 省略不可**:
   - `git status` でシークレット・不要ファイルの混入が無いことを確認する。
   - `git add -A` → `git commit` → `git push origin <branch>` → **PR を既定ブランチへマージ**する。ドラフトなら Ready 化してからマージ。コンフリクトは解消する。解消できない対立はユーザーに上げる。
   - *(PR作成・マージを行うのは「次セッションへ引き継ぐ」チェックアウトの場合。引き継ぎ不要の中間作業ではユーザー指示に従う。)*

3. **到達性の検証 — これを満たすまで完了と宣言しない**:
   - `git fetch origin <既定ブランチ>` の後、**既定ブランチ上に**更新済み handoff と今セッションの変更が乗っていることを、実際の `git` 出力で示す（例: `git log origin/main --oneline -5`、`git diff origin/main -- docs/` が空）。
   - **合言葉**: 「新規コンテナが既定ブランチをクローンして始まっても、今の到達点が丸ごと残っているか？」

## 禁止事項 (Do Not)
- 既定ブランチに未マージのまま「チェックアウト完了」と宣言しない。
- 検証（手順3）を自己申告で済ませない。**実際の `git` 出力で示す**（AGENTS.md A-7）。
