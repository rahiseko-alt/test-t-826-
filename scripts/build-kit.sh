#!/usr/bin/env bash
#
# build-kit.sh — 配る一式を組み立て、照合用の値を画面へ埋め込む
#
# 【何をするか】
#   1. dist/shitaku-kit.tar.gz を組み立てる
#   2. その SHA-256 を計算する
#   3. index.html の KIT_SHA256 を、その値へ置き換える
#
# 【なぜ手で書かないか】
#   画面に書く値と、実際に配る一式は、常に同じでなければならない。
#   人が写すと必ずいつかずれる。ずれた瞬間、利用者側の照合は必ず失敗し、
#   誰も一式を受け取れなくなる。だからここで機械的に埋める。
#
# 【一式に何が入るか】
#   このリポジトリの現物をそのまま入れる。中身を書き写さない（D-7 ルールの正は1つ）。
#   ただし spec.md と docs/ は、案件ごとに空から始めるため templates/kit/ の雛形を使う。
#
# 依存: bash / tar / shasum または sha256sum
#
# 使い方:
#   bash scripts/build-kit.sh
#
# 終了コード: 0 = 成功 / 1 = 失敗

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
TARBALL="$DIST/shitaku-kit.tar.gz"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# --- 1. 組み立て ---------------------------------------------------------
mkdir -p "$STAGE/kit"
K="$STAGE/kit"

copy() {
  src="$ROOT/$1"
  dst="$K/${2:-$1}"
  if [ ! -e "$src" ]; then
    echo "要対応: $1 が見つかりません。一式を組み立てられません。" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

copy AGENTS.md
copy AGENTS.md CLAUDE.md          # 読みに行く名前がAIごとに違うため、同じ中身を両方の名前で置く
copy prompts
copy .agents
copy templates/e2e
copy scripts/check-test-integrity.sh scripts/check-test-integrity.sh
copy scripts/check-catastrophic.sh  scripts/check-catastrophic.sh
copy scripts/verify-install.sh      scripts/verify-install.sh
copy templates/kit/spec.md          spec.md
copy templates/kit/docs             docs

# 案件を始める人が最初に読む1枚。中身を読むのはAIであって人ではない、と伝える。
cat > "$K/はじめに.txt" <<'EOF'
このフォルダの中身は、AIが読むためのものです。
あなたが読む必要はありません。

次に、AIへこう言ってください。

    このフォルダの AGENTS.md と spec.md を読んで、続きをやってください。

以上です。
EOF

# --- 2. 固める -----------------------------------------------------------
mkdir -p "$DIST"
# 中身が同じなら毎回同じ tarball になるようにする。日付や順序で値が変わると、
# 画面に埋めた照合用の値が意味を持たなくなる。
( cd "$STAGE/kit" && find . -type f | LC_ALL=C sort > "$STAGE/list" )
tar --format=ustar \
    --mtime='2026-01-01 00:00:00 UTC' \
    --owner=0 --group=0 --numeric-owner \
    -C "$STAGE/kit" -T "$STAGE/list" -czf "$TARBALL" 2>/dev/null \
  || tar -C "$STAGE/kit" -czf "$TARBALL" .

# --- 3. 照合用の値を計算する ---------------------------------------------
if command -v shasum >/dev/null 2>&1; then
  SUM="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
elif command -v sha256sum >/dev/null 2>&1; then
  SUM="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
else
  echo "要対応: shasum も sha256sum も見つかりません。照合用の値を計算できません。" >&2
  exit 1
fi

# --- 4. 画面へ埋める -----------------------------------------------------
INDEX="$ROOT/index.html"
if ! grep -q "var KIT_SHA256 = '" "$INDEX"; then
  echo "要対応: index.html に KIT_SHA256 の行が見つかりません。" >&2
  exit 1
fi
TMP="$STAGE/index.html"
sed "s/var KIT_SHA256 = '[0-9a-f]\{64\}';/var KIT_SHA256 = '$SUM';/" "$INDEX" > "$TMP"
cp "$TMP" "$INDEX"

FILES="$(wc -l < "$STAGE/list" | tr -d ' ')"
SIZE="$(wc -c < "$TARBALL" | tr -d ' ')"

echo "問題なし"
echo
echo "  一式        $TARBALL"
echo "  ファイル数  $FILES"
echo "  大きさ      $SIZE バイト"
echo "  照合用の値  $SUM"
echo
echo "index.html に上の値を埋めました。"
echo "この tar.gz を配布先へ置けば、出荷できます。"
