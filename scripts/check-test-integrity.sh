#!/usr/bin/env bash
# ============================================================================
# check-test-integrity.sh — テスト無効化の検出
#
# 目的:
#   D-20260825-18 第4節「テストの無効化を検出する」(制約3) の実装。
#   検査そのものを弱めて緑にする経路を、差分の増減だけで機械判定する。
#   同記録 第2節のとおり、lint は「設定ファイルで規則を消す」「行末に免除を
#   書く」の2手で、コードを1文字も変えずに緑にできる。本スクリプトは
#   その2手を含む5クラスを `git diff <BASE>...HEAD` から数える。
#
# 依存: bash 3.2+ / git / grep / sed / cut / sort / head / wc のみ。
#       Node・Python・jq は使わない (scripts/check-discussions.sh と同じ方針)。
#
# 使い方:
#   scripts/check-test-integrity.sh [BASE] [SPEC]
#     BASE  比較の基点。省略時 origin/master。例: HEAD~1 / origin/main
#     SPEC  案件の spec.md のパス (リポジトリルートからの相対)。
#           省略時は git 管理下の `*/spec.md` と `spec.md` を自動探索する。
#   終了コード:
#     0 = 検出ゼロ
#     1 = 1件以上検出
#     2 = 前提不成立 (git リポジトリでない / BASE が解決できない)
#
# しきい値:
#   **増加ゼロ。** 1件でも増えたら 1 を返す。
#   「N件までは許容」という緩和は置かない。緩和した瞬間に、緩和の幅だけ
#   無効化が通る。増減の判定に人間の裁量が入る余地を作らない。
#
# ---------------------------------------------------------------------------
# 【検査する = 差分を数えるだけで機械判定できるもの】
#   T1 テストファイルの削除、またはテストファイルの行数減
#       - 削除 (name-status の D) は無条件で ERROR
#       - 変更後の増減が負 (追加行 < 削除行) なら ERROR
#       - テストファイルの判定はパス名の形 (下の TEST_FILE_RE)
#   T2 `skip` `only` `xfail` `todo` の増加
#       - 追加行での出現数 − 削除行での出現数 > 0 で ERROR
#   T3 `noqa` `eslint-disable` `ts-ignore` `type: ignore` の増加
#       - 同上。nolint / rubocop:disable / pylint: disable / SuppressWarnings も
#         同じクラスとして数える (行末に免除を書く手口は言語をまたぐ)
#       ※ T2・T3 の走査対象から次の2つを外す。
#         (a) 本スクリプトと scripts/check-catastrophic.sh
#             検出パターンの文字列そのものが検出されるため。
#             この自己除外は検査の穴になる。scripts/ 配下は人が読むこと。
#         (b) Markdown ファイル (*.md / *.mdx)
#             免除の記法は実行される言語にしか効かない。説明文に書かれた
#             `skip` や `noqa` を数えると、検査の説明を書くたびに赤になる。
#             ただし spec.md は T5 で別に検査する。
#   T4 lint・型チェックの設定ファイルで `ignore` が増えた
#       - 対象は CONFIG_FILE_RE に当たるファイルのみ
#       - **語の出現回数ではなく、免除の「項目数」の増加**で判定する。
#         既存の一覧に項目を足す形 (["dist"] -> ["dist","src"]) は語の数が
#         増えないため、出現回数で数えると素通りする。これは
#         「設定ファイルで規則を消す」手口 (D-20260825-18 第2節) の典型。
#       - 設定ファイルそのものの削除も ERROR とする
#   T5 spec.md の検収条件 (通し操作) の手順数の減少
#       - spec.md 第2節に含まれる Given / When / Then (および 前提 / 操作 /
#         期待) の行数を BASE と HEAD で数え、減っていたら ERROR
#       - spec.md が BASE に有り HEAD に無い (削除された) なら ERROR
#
# 【検査しない = 差分の増減に還元できないもの】
#   - 追加された `skip` に正当な理由があるか (期限付きの一時無効化か、恒久か)
#   - テストの中身が空になっていないか (行数は保ったまま assert を消す手口)
#     ※ これは差分の行数では捕まらない。D-20260825-18 第6節が
#       ミューテーションテストを「見送り」とし、再検討トリガーを
#       「無効化検出で捕まらない偽解決が出た場合」と定めている。
#   - 削除されたテストが別ファイルに移されただけか
#   本スクリプトが緑であることは「検査が十分」の証明ではなく、
#   「検査を弱める方向の差分が無い」ことの証明にすぎない。
#
# 【誤検知について】
#   増加ゼロというしきい値の帰結として、正当な変更 (例: 配列メソッドの
#   `.only` に見える別 API、設定ファイルの無関係な `exclude` 追加) も
#   ERROR になる。これは想定内である。通したい場合は差分を分けるか、
#   人間がその1件を明示的に承認する。しきい値は緩めない。
# ============================================================================

set -u

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)
if ! git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf 'FATAL: git リポジトリではない: %s\n' "$REPO_ROOT" >&2
  exit 2
fi
REPO_ROOT=$(git -C "$REPO_ROOT" rev-parse --show-toplevel)

BASE=${1:-origin/master}
SPEC_ARG=${2:-}

if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  printf 'FATAL: BASE を解決できない: %s\n' "$BASE" >&2
  printf 'HINT : 第1引数で基点を渡す (例: scripts/check-test-integrity.sh HEAD~1)\n' >&2
  exit 2
fi

TAB=$(printf '\t')
ERRORS=0
WARNS=0

err() { # err <file> <line|-> <msg>
  printf 'ERROR %s:%s: %s\n' "$1" "$2" "$3"
  ERRORS=$((ERRORS + 1))
}
warn() { # warn <file> <line|-> <msg>
  printf 'WARN  %s:%s: %s\n' "$1" "$2" "$3"
  WARNS=$((WARNS + 1))
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/check-test-integrity.XXXXXX") || exit 2
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# パス分類の正規表現 (単一の真実の源。ここだけを直せば分類が変わる)
# ---------------------------------------------------------------------------
TEST_FILE_RE='(^|/)(tests?|__tests__|specs?|e2e|integration|acceptance)/|(^|/)[^/]*[._-](test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|(^|/)[^/]*_test\.(go|py|rb|ex|exs|rs|ts|js)$|(^|/)conftest\.py$|(^|/)[^/]*Tests?\.(java|kt|cs|swift|scala)$'

CONFIG_FILE_RE='(^|/)(\.eslintrc[^/]*|eslint\.config\.[cm]?[jt]s|\.eslintignore|tsconfig[^/]*\.json|jsconfig\.json|\.flake8|setup\.cfg|pyproject\.toml|ruff\.toml|\.ruff\.toml|mypy\.ini|\.mypy\.ini|tox\.ini|pylintrc|\.pylintrc|biome\.jsonc?|\.stylelintrc[^/]*|\.golangci\.ya?ml|\.rubocop\.ya?ml|phpstan\.neon|psalm\.xml|\.swiftlint\.yml|checkstyle\.xml)$'

# T2: skip / only / xfail / todo
P_SKIP='\.skip([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(xit|xdescribe|xcontext|xtest)[[:space:]]*\(|@(pytest\.mark\.)?skip(if)?([^A-Za-z0-9_]|$)|@unittest\.skip|(^|[^A-Za-z0-9_])t\.Skip[A-Za-z]*[[:space:]]*\(|#\[ignore\]'
P_ONLY='\.only([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])(fit|fdescribe|fcontext)[[:space:]]*\('
P_XFAIL='xfail|expectedFailure|@Ignore([^A-Za-z0-9_]|$)'
P_TODO='\.todo([^A-Za-z0-9_]|$)'

# T3: 行末に書く免除
P_NOQA='(^|[^A-Za-z0-9_])noqa([^A-Za-z0-9_]|$)'
P_ESLINT_DISABLE='eslint-disable(-next-line|-line)?([^A-Za-z0-9_-]|$)'
P_TS_IGNORE='@ts-ignore|@ts-nocheck|@ts-expect-error'
P_TYPE_IGNORE='type:[[:space:]]*ignore'
P_OTHER_EXEMPT='//[[:space:]]*nolint|rubocop:disable|pylint:[[:space:]]*disable|@SuppressWarnings|#[[:space:]]*shellcheck[[:space:]]+disable'

# T4: 設定ファイルでの免除
#   語の出現回数では判定しない。既存の一覧に項目を足す形
#   ("ignorePatterns": ["dist"] -> ["dist","src"]) は語の数が増えないため、
#   出現回数で数えると素通りする。これは「設定ファイルで規則を消して緑にする」
#   手口の典型 (D-20260825-18 第2節) なので、免除の「項目数」で数える。
P_CFG_KEY='[Ii]gnore[A-Za-z_-]*|[Ee]xclude[A-Za-z_-]*|[Dd]isable[A-Za-z_-]*|skipLibCheck|"off"|'\''off'\'''
# ファイル全体が免除の一覧であるもの (鍵を持たない)
IGNORE_FILE_RE='(^|/)(\.eslintignore|\.stylelintignore|\.prettierignore)$'

# T5: 検収条件の手順行
P_GWT='(^|[^A-Za-z])(Given|When|Then|And)([^A-Za-z]|$)|前提|操作|期待'

# ---------------------------------------------------------------------------
# 1. 差分の展開
#    "<符号><TAB><パス><TAB><行番号><TAB><内容>" の1行1レコードに正規化する。
#    行番号は追加行なら HEAD 側、削除行なら BASE 側の番号。
# ---------------------------------------------------------------------------
git -C "$REPO_ROOT" diff --no-color --no-ext-diff --unified=0 -M "$BASE...HEAD" > "$TMPD/diff" 2>/dev/null

cur=""
nl=0
ol=0
hdr_wait=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    'diff --git '*) cur=""; hdr_wait=1; continue ;;
  esac
  if [ "$hdr_wait" -eq 1 ]; then
    case "$line" in
      '--- '*) continue ;;
      '+++ '*)
        p=${line#+++ }
        if [ "$p" = "/dev/null" ]; then cur=""; else cur=${p#b/}; fi
        hdr_wait=0
        continue
        ;;
      '@@'*) hdr_wait=0 ;;
      *) continue ;;
    esac
  fi
  case "$line" in
    '@@'*)
      hdr=${line#@@ }
      hdr=${hdr%%@@*}
      oldpart=${hdr%% *}
      newpart=${hdr#* }
      newpart=${newpart%% *}
      ol=${oldpart#-}; ol=${ol%%,*}
      nl=${newpart#+}; nl=${nl%%,*}
      case "$ol" in ''|*[!0-9]*) ol=0 ;; esac
      case "$nl" in ''|*[!0-9]*) nl=0 ;; esac
      continue
      ;;
  esac
  [ -n "$cur" ] || continue
  case "$line" in
    '+'*) printf '+%s%s%s%s%s%s\n' "$TAB" "$cur" "$TAB" "$nl" "$TAB" "${line#+}"; nl=$((nl + 1)) ;;
    '-'*) printf -- '-%s%s%s%s%s%s\n' "$TAB" "$cur" "$TAB" "$ol" "$TAB" "${line#-}"; ol=$((ol + 1)) ;;
    ' '*) nl=$((nl + 1)); ol=$((ol + 1)) ;;
  esac
done < "$TMPD/diff" > "$TMPD/lines"

# パスを grep -E の literal として使えるようにエスケープする
esc_path() { printf '%s' "$1" | sed 's/[].[^$*+?(){}|\\]/\\&/g'; }

# lines_of_paths <改行区切りのパス集合> <出力ファイル>
#   レコード集合をパスで絞り込んだ部分集合を作る。
#   ※ パス分類の ERE を「符号<TAB>パス<TAB>」の中に埋め込むと、ERE 中の `^` が
#     行頭アンカーとして解釈されて (^|/) が機能しない。分類は必ずパス単体に
#     対して行い、絞り込みは具体的なパス名で行う。
lines_of_paths() {
  local out=$2 p e
  : > "$out"
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    e=$(esc_path "$p")
    grep -E "^[-+]${TAB}${e}${TAB}" "$TMPD/lines" >> "$out" 2>/dev/null || true
  done <<EOF
$1
EOF
}

# stream <符号(+|-)> <レコードファイル> -> レコード行
stream() {
  grep -E "^[${1}]${TAB}" "$2" 2>/dev/null || true
}

# occurrences <符号> <レコードファイル> <検出のERE> -> 出現数 (行数ではなく出現数)
occurrences() {
  local n
  n=$(stream "$1" "$2" | cut -f4- | grep -Eo "$3" 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# report_added <レコードファイル> <検出のERE> <見出し>
#   追加側の該当行を file:line 付きで全件出力する (何が増えたかを人が読めるように)
report_added() {
  local src=$1 pat=$2 label=$3 rec f ln body
  stream '+' "$src" | grep -E "$pat" 2>/dev/null | while IFS= read -r rec; do
    rec=${rec#+"$TAB"}
    f=${rec%%"$TAB"*}
    rec=${rec#*"$TAB"}
    ln=${rec%%"$TAB"*}
    body=${rec#*"$TAB"}
    body=${body#"${body%%[![:space:]]*}"}
    printf '      %s:%s: %s: %s\n' "$f" "$ln" "$label" "${body:0:120}"
  done
}

# check_delta <レコードファイル> <検出のERE> <クラスID> <見出し>
check_delta() {
  local src=$1 pat=$2 id=$3 label=$4 a d delta
  [ -s "$src" ] || return 0
  a=$(occurrences '+' "$src" "$pat")
  d=$(occurrences '-' "$src" "$pat")
  delta=$((a - d))
  if [ "$delta" -gt 0 ]; then
    err "(diff)" "-" "$id $label が増えた: 追加 ${a} 件 / 削除 ${d} 件 (増加 ${delta} 件)"
    ERRORS=$((ERRORS + delta - 1))   # err() で 1 件加算済み。増加分だけ数える
    report_added "$src" "$pat" "$label"
  fi
}

# ---------------------------------------------------------------------------
# 2. T1: テストファイルの削除・行数減
# ---------------------------------------------------------------------------
git -C "$REPO_ROOT" diff --no-color --no-ext-diff --name-status -M "$BASE...HEAD" > "$TMPD/namestatus" 2>/dev/null
while IFS= read -r row || [ -n "$row" ]; do
  [ -n "$row" ] || continue
  st=${row%%"$TAB"*}
  rest=${row#*"$TAB"}
  case "$st" in
    D*)
      path=$rest
      if printf '%s' "$path" | grep -Eq "$TEST_FILE_RE"; then
        err "$path" "-" "T1 テストファイルが削除された"
      fi
      ;;
  esac
done < "$TMPD/namestatus"

git -C "$REPO_ROOT" diff --no-color --no-ext-diff --numstat -M "$BASE...HEAD" > "$TMPD/numstat" 2>/dev/null
while IFS= read -r row || [ -n "$row" ]; do
  [ -n "$row" ] || continue
  add=${row%%"$TAB"*}
  rest=${row#*"$TAB"}
  del=${rest%%"$TAB"*}
  path=${rest#*"$TAB"}
  # リネーム表記 "old => new" / "pre{old => new}post" は新しい側を採る
  case "$path" in
    *' => '*) path=$(printf '%s' "$path" | sed -E 's/\{([^}]*) => ([^}]*)\}/\2/; s/^.* => //') ;;
  esac
  case "$add" in ''|*[!0-9]*) continue ;; esac   # バイナリ差分 ("-") は対象外
  case "$del" in ''|*[!0-9]*) continue ;; esac
  printf '%s' "$path" | grep -Eq "$TEST_FILE_RE" || continue
  if [ "$((add - del))" -lt 0 ]; then
    err "$path" "-" "T1 テストファイルの行数が減った: +${add} / -${del} (差 $((add - del)) 行)"
    shown=0
    lines_of_paths "$path" "$TMPD/lines.one"
    stream '-' "$TMPD/lines.one" | while IFS= read -r rec; do
      rec=${rec#-"$TAB"}
      rec=${rec#*"$TAB"}
      lnn=${rec%%"$TAB"*}
      bodyy=${rec#*"$TAB"}
      bodyy=${bodyy#"${bodyy%%[![:space:]]*}"}
      shown=$((shown + 1))
      if [ "$shown" -le 10 ]; then
        printf '      %s:%s: 削除された行: %s\n' "$path" "$lnn" "${bodyy:0:120}"
      elif [ "$shown" -eq 11 ]; then
        printf '      %s: (削除行が多いため以降は省略)\n' "$path"
      fi
    done
  fi
done < "$TMPD/numstat"

# ---------------------------------------------------------------------------
# 3. T2: skip / only / xfail / todo の増加
#    走査対象は lines.scan (検査スクリプト自身と Markdown を除いた集合)
# ---------------------------------------------------------------------------
grep -Ev "^[-+]${TAB}(scripts/check-test-integrity\.sh|scripts/check-catastrophic\.sh|[^${TAB}]*\.mdx?)${TAB}" \
     "$TMPD/lines" > "$TMPD/lines.scan" 2>/dev/null || : > "$TMPD/lines.scan"

check_delta "$TMPD/lines.scan" "$P_SKIP"  "T2" "skip"
check_delta "$TMPD/lines.scan" "$P_ONLY"  "T2" "only"
check_delta "$TMPD/lines.scan" "$P_XFAIL" "T2" "xfail"
check_delta "$TMPD/lines.scan" "$P_TODO"  "T2" "todo"

# ---------------------------------------------------------------------------
# 4. T3: 行末の免除の増加
# ---------------------------------------------------------------------------
check_delta "$TMPD/lines.scan" "$P_NOQA"           "T3" "noqa"
check_delta "$TMPD/lines.scan" "$P_ESLINT_DISABLE" "T3" "eslint-disable"
check_delta "$TMPD/lines.scan" "$P_TS_IGNORE"      "T3" "ts-ignore"
check_delta "$TMPD/lines.scan" "$P_TYPE_IGNORE"    "T3" "type: ignore"
check_delta "$TMPD/lines.scan" "$P_OTHER_EXEMPT"   "T3" "その他の行内免除 (nolint / rubocop:disable / pylint: disable / SuppressWarnings)"

# ---------------------------------------------------------------------------
# 5. T4: lint・型チェックの設定ファイルで免除の「項目数」が増えた
#
#    数えるのは語の出現回数ではなく、免除の対象として列挙された項目の数。
#    次のいずれの書き方も1項目ずつ数える。
#      "ignorePatterns": ["dist","src"]        JSON の1行配列
#      "exclude": [                            JSON の複数行配列
#        "dist",
#        "src"
#      ]
#      ignore:                                 YAML のリスト
#        - dist
#        - src
#      extend-ignore = E203, W503              ini のカンマ区切り
#      "no-console": "off"                     規則を1つ消す書き方
#    加えて、免除の鍵 (ignore / exclude / disable / skipLibCheck) そのものを
#    1項目と数える。鍵が新設された場合も増加として捕まえるため。
#    .eslintignore のようにファイル全体が一覧であるものは、
#    コメントと空行を除いた行数をそのまま項目数とする。
# ---------------------------------------------------------------------------

# count_items <文字列> -> その行に含まれる免除項目の数
count_items() {
  local s=$1 q n t
  q=$(printf '%s' "$s" | grep -Eo '"[^"]*"|'\''[^'\'']*'\''' 2>/dev/null | grep -c '' | tr -d '[:space:]')
  case "$q" in ''|*[!0-9]*) q=0 ;; esac
  if [ "$q" -gt 0 ]; then printf '%s' "$q"; return 0; fi
  # YAML の "- 項目"
  if printf '%s' "$s" | grep -Eq '^[[:space:]]*-[[:space:]]*[^[:space:]]'; then printf '1'; return 0; fi
  # 引用符なしのカンマ区切り (ini / flake8 の extend-ignore = E203, W503 など)
  t=$(printf '%s' "$s" | sed -E 's/^[[:space:]]*[[({]?[[:space:]]*//; s/[[:space:]]*[])}],?[[:space:]]*$//; s/[[:space:]]*$//')
  if [ -z "$t" ]; then printf '0'; return 0; fi
  n=$(printf '%s' "$t" | grep -o ',' | grep -c '' | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$((n + 1))"
}

# exempt_item_count <実ファイル> <表示用パス> -> 免除項目の総数
#   section2_count() と同じ方式の小さな状態機械。
#   「鍵の行」で列が始まり、閉じ括弧か字下げの無い行で列が終わる。
exempt_item_count() {
  local f=$1 p=$2 total=0 inlist=0 l rest n
  [ -f "$f" ] || { printf '0'; return 0; }
  if printf '%s' "$p" | grep -Eq "$IGNORE_FILE_RE"; then
    total=$(grep -Ec '^[[:space:]]*[^#[:space:]]' "$f" 2>/dev/null | tr -d '[:space:]')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    printf '%s' "$total"
    return 0
  fi
  while IFS= read -r l || [ -n "$l" ]; do
    if printf '%s' "$l" | grep -Eq "($P_CFG_KEY)"; then
      total=$((total + 1))
      rest=$(printf '%s' "$l" | sed -E "s/^.*($P_CFG_KEY)[\"']?[[:space:]]*[:=]?//")
      n=$(count_items "$rest")
      total=$((total + n))
      # 開いたまま行が終わっていれば、次の行以降も同じ列とみなす
      if printf '%s' "$rest" | grep -Eq '\[[^]]*$|\{[^}]*$|^[[:space:]]*$'; then inlist=1; else inlist=0; fi
    elif [ "$inlist" -eq 1 ]; then
      if printf '%s' "$l" | grep -Eq '^[[:space:]]*[]})]|^[^[:space:]-]'; then
        inlist=0
      else
        n=$(count_items "$l")
        total=$((total + n))
      fi
    fi
  done < "$f"
  printf '%s' "$total"
}

CONFIG_PATHS=$(git -C "$REPO_ROOT" diff --no-color --no-ext-diff --name-only -M "$BASE...HEAD" 2>/dev/null \
                 | grep -E "$CONFIG_FILE_RE" || true)
while IFS= read -r cf || [ -n "$cf" ]; do
  [ -n "$cf" ] || continue
  cfg_base=0
  cfg_head=0
  cfg_base_exists=0
  if git -C "$REPO_ROOT" cat-file -e "$BASE:$cf" 2>/dev/null; then
    cfg_base_exists=1
    git -C "$REPO_ROOT" show "$BASE:$cf" > "$TMPD/cfg_base" 2>/dev/null
    cfg_base=$(exempt_item_count "$TMPD/cfg_base" "$cf")
  fi
  if [ -f "$REPO_ROOT/$cf" ]; then
    cfg_head=$(exempt_item_count "$REPO_ROOT/$cf" "$cf")
  elif [ "$cfg_base_exists" -eq 1 ]; then
    err "$cf" "-" "T4 lint・型チェックの設定ファイルが削除された (規則そのものが消えている)"
    continue
  fi
  if [ "$cfg_head" -gt "$cfg_base" ]; then
    err "$cf" "-" "T4 免除の項目数が増えた: BASE ${cfg_base} 項目 -> HEAD ${cfg_head} 項目 (増加 $((cfg_head - cfg_base)) 項目)"
    ERRORS=$((ERRORS + (cfg_head - cfg_base) - 1))
    lines_of_paths "$cf" "$TMPD/lines.cfg"
    report_added "$TMPD/lines.cfg" "($P_CFG_KEY)|^[[:space:]]*[-\"']" "免除の記述"
  fi
done <<EOF
$CONFIG_PATHS
EOF

# ---------------------------------------------------------------------------
# 6. T5: spec.md 第2節 (検収条件) の手順数の減少
# ---------------------------------------------------------------------------
# section2 <ファイル内容のパス> -> 第2節の本文
section2_count() { # <file> -> 第2節に含まれる手順行の数
  local f=$1 in2=0 n=0 l
  while IFS= read -r l || [ -n "$l" ]; do
    if printf '%s' "$l" | grep -Eq '^##[[:space:]]+2[.．]'; then in2=1; continue; fi
    if [ "$in2" -eq 1 ]; then
      if printf '%s' "$l" | grep -Eq '^#{1,2}[[:space:]]'; then break; fi
      if printf '%s' "$l" | grep -Eq "$P_GWT"; then n=$((n + 1)); fi
    fi
  done < "$f"
  printf '%s' "$n"
}

SPECS=""
if [ -n "$SPEC_ARG" ]; then
  SPECS=$SPEC_ARG
else
  SPECS=$( { git -C "$REPO_ROOT" ls-files; git -C "$REPO_ROOT" ls-tree -r --name-only "$BASE"; } 2>/dev/null \
            | grep -E '(^|/)spec\.md$' | sort -u )
fi

if [ -z "$SPECS" ]; then
  warn "(spec)" "-" "T5 spec.md が見つからないため検収条件の手順数を検査できない (第2引数でパスを渡せる)"
else
  while IFS= read -r sp || [ -n "$sp" ]; do
    [ -n "$sp" ] || continue
    base_n=0
    head_n=0
    base_exists=0
    head_exists=0
    if git -C "$REPO_ROOT" cat-file -e "$BASE:$sp" 2>/dev/null; then
      base_exists=1
      git -C "$REPO_ROOT" show "$BASE:$sp" > "$TMPD/spec_base" 2>/dev/null
      base_n=$(section2_count "$TMPD/spec_base")
    fi
    if [ -f "$REPO_ROOT/$sp" ]; then
      head_exists=1
      head_n=$(section2_count "$REPO_ROOT/$sp")
    fi
    if [ "$base_exists" -eq 1 ] && [ "$head_exists" -eq 0 ]; then
      err "$sp" "-" "T5 spec.md が削除された (検収条件そのものが消えている)"
      continue
    fi
    if [ "$base_exists" -eq 0 ]; then
      continue   # 新規追加された spec.md。減少はありえない
    fi
    if [ "$head_n" -lt "$base_n" ]; then
      err "$sp" "-" "T5 検収条件 (第2節) の手順数が減った: BASE ${base_n} 行 -> HEAD ${head_n} 行 (差 $((head_n - base_n)))"
      ERRORS=$((ERRORS + (base_n - head_n) - 1))
      lines_of_paths "$sp" "$TMPD/lines.spec"
      stream '-' "$TMPD/lines.spec" | grep -E "$P_GWT" 2>/dev/null | while IFS= read -r rec; do
        rec=${rec#-"$TAB"}
        rec=${rec#*"$TAB"}
        lnn=${rec%%"$TAB"*}
        bodyy=${rec#*"$TAB"}
        bodyy=${bodyy#"${bodyy%%[![:space:]]*}"}
        printf '      %s:%s: 削除された手順行: %s\n' "$sp" "$lnn" "${bodyy:0:120}"
      done
    fi
  done <<< "$SPECS"
fi

# ---------------------------------------------------------------------------
# 7. 集計
# ---------------------------------------------------------------------------
changed=$(grep -c '' "$TMPD/numstat" 2>/dev/null | tr -d '[:space:]')
case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
printf -- '---\n'
printf 'base: %s (%s)\n' "$BASE" "$(git -C "$REPO_ROOT" rev-parse --short "$BASE" 2>/dev/null)"
printf 'changed files: %s\n' "$changed"
printf 'ERROR: %d / WARN: %d\n' "$ERRORS" "$WARNS"
if [ "$ERRORS" -gt 0 ]; then
  printf 'RESULT: FAIL (しきい値は増加ゼロ。1件でも増えたら落とす)\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
