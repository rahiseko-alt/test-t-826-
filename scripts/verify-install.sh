#!/usr/bin/env bash
#
# verify-install.sh — 一式が正しく置けたかを確かめる
#
# 【この検査が見るもの】
#   展開した一式に、必要なファイルが揃っていて、中身が空でないこと。
#
# 【この検査が見ないもの】
#   取ってきたものが途中で壊れていないか。それはハッシュ値の照合が担う
#   （指示書の手順2）。ここでその照合をやり直すと、届いたものを届いたもので
#   検証することになり、意味を持たない。役割を混ぜない。
#
# 【出力の約束】
#   1行目に「問題なし」か「要対応」のどちらかを必ず出す（spec.md 第2節 A-5）。
#   AIはこの出力をそのまま利用者に見せること。合格でなければ完了と言わない。
#
# 依存: bash 3.2+ / grep のみ。
#
# 使い方:
#   bash scripts/verify-install.sh [一式のルート]
#   省略時はこのスクリプトの1つ上のディレクトリを見る。
#
# 終了コード:
#   0 = 問題なし
#   1 = 要対応（欠け・空・読めない）

set -u

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

# 一式に必ず入っているもの。ここを減らすと検査が弱くなる。
REQUIRED="
AGENTS.md
spec.md
prompts/intent-backtranslator.md
prompts/drift-detector.md
scripts/check-test-integrity.sh
scripts/check-catastrophic.sh
templates/e2e/acceptance.spec.ts
.agents/skills/session-checkin/SKILL.md
.agents/skills/project-spec/SKILL.md
.agents/skills/verified-plan/SKILL.md
"

PROBLEMS=""
COUNT=0
OK=0

add_problem() {
  PROBLEMS="${PROBLEMS}  - $1
"
}

for rel in $REQUIRED; do
  COUNT=$((COUNT + 1))
  path="$ROOT/$rel"
  if [ ! -e "$path" ]; then
    add_problem "$rel が見つかりません"
  elif [ ! -r "$path" ]; then
    add_problem "$rel を読めません（権限）"
  elif [ ! -s "$path" ]; then
    add_problem "$rel が空です"
  else
    OK=$((OK + 1))
  fi
done

# AGENTS.md が本物か。名前だけ同じ空の器を掴まされていないかを見る。
if [ -s "$ROOT/AGENTS.md" ]; then
  if ! grep -q "この案件が向かう先" "$ROOT/AGENTS.md" 2>/dev/null; then
    add_problem "AGENTS.md の中身が想定と違います（ゴールの掲示が見つかりません）"
  fi
fi

# 1行目は必ず判定。見出しや対象パスを先に出すと、利用者が最初に読む行が
# 判定でなくなる（spec.md 第2節 A-5 が赤になる）。ここへ何かを足さないこと。
if [ -z "$PROBLEMS" ]; then
  echo "問題なし"
  echo
  echo "一式は揃っています。このまま開発を始められます。"
  echo
  echo "（確認したもの ${OK} / ${COUNT}  場所 $ROOT）"
  exit 0
fi

echo "要対応"
echo
echo "次のものが揃っていません。"
echo "$PROBLEMS"
echo "取得か展開が途中で終わっている可能性があります。"
echo "もう一度、指示書の手順1からやり直してください。"
echo "この状態で作業を進めてはいけません。"
echo
echo "（確認したもの ${OK} / ${COUNT}  場所 $ROOT）"
exit 1
