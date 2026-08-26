---
name: session-checkin
description: >-
  Use this skill at the beginning of a working session. Reads the always-on goal and
  docs/handoff.md, checks git state, and starts work. Does NOT ask the user to confirm
  anything — the goal is fixed once when it is set, not once per session.
---

# Session Check-in Skill (セッション開始プロトコル)

セッション開始時 (`In`) の手順。**ユーザーへの確認を含めない。** 前セッションの続きを、そのまま続ける。

> **ここで門①（ずれ①・逆翻訳の二択）は回さない。** 門①は**新しいゴールを決めるときに1回だけ**回す
> （`AGENTS.md` 冒頭）。
> ゴールは1案件（受注した開発）につき最初に1回決めるものであり、毎セッション確認するのは儀式である。

## 手順 (Workflow)

1. **[`AGENTS.md`](../../../AGENTS.md) 冒頭の「🎯 この案件が向かう先」を読む。** 望ましい未来1件・避けるべき未来5件に、これからの差分を照合する。
2. **[`docs/handoff.md`](../../../docs/handoff.md) を読む。** 現在の状態と次にやることを把握する。必要なら [`docs/design.md`](../../../docs/design.md) と [`spec.md`](../../../spec.md) を見る。
3. **`git status` / `git branch` で現在地を確認する。**
4. **次にやることに着手する。** 手が止まる要因が実際に出たときだけユーザーに上げる。
   - 新しい案件を始める場合は [`project-spec` スキル](../project-spec/SKILL.md) に従い、`spec.md` を確定させてから実装に入る（AGENTS.md D-1）。

## 禁止事項 (Do Not)
- `docs/failures.md` 全文を読み込まない（コンテキスト汚染防止）。必要時に `failure-matcher` で照合する。
- **手が止まっていないのにユーザーへ確認を投げない。** 確認の回数はゴールを決めるときの二択1回に限る。
