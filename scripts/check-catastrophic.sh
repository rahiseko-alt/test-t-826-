#!/usr/bin/env bash
# ============================================================================
# check-catastrophic.sh — 破滅的な脆弱性の検査 (4種のみ)
#
# 目的:
#   D-20260825-18 第4節「破滅的な脆弱性（4種のみ）」の実装。
#   利用者が知りたいことの片方 (b)「破滅的な脆弱性は無いか」を機械で見る。
#   種類は4種に限定する。網羅的なセキュリティ検査ではない。
#
# ---------------------------------------------------------------------------
# 【設計原則: 感度優先・特異度は捨てる。誤検知は想定内でありコストではない】
#   D-20260825-14 第4節 (門②) と同じ原則を採る。迷ったら検出する。
#   本スクリプトの誤検知は「人が1行読んで違うと分かる」形で出力されるため、
#   見逃し1件のコストと釣り合わない。特異度を上げる改修は入れない。
#   誤検知を減らしたいときは、精度ではなく**検査対象の範囲**で調整する
#   (D-20260825-14: 人間に届く誤検知の量 = 対象件数 × (1 − 特異度))。
#
# 【静かな見逃しを構造的に禁止する】
#   C3 (認証の抜け) は spec.md 第4節の「保護対象ルート一覧」を入力に取る。
#   一覧が見つからない、または項目が0行なら **exit 1 で落とす**。
#   「検査対象が分からないので何も検出せず緑」は、最も危険な緑である。
#   静かに間違えるより、うるさく落ちるほうを選ぶ (D-20260825-18 第4節)。
#
#   ただし **`- NONE` という明示的な宣言がある場合だけは SKIP** とし、
#   exit code には算入せず他の3種を継続する (C2 と同じ扱い)。
#   認証を持たない案件は実在し、そこで恒久的に赤になると検査そのものを
#   外す動機を作る。それは D-20260825-18 が名指しした「無効化の温床」であり、
#   検査を守るはずの設計が検査を殺す。
#   区別するのは「宣言したか」である。宣言があれば SKIP、
#   何も書いていなければ ERROR。書き忘れが静かに緑になる経路は塞いだままになる。
#
# ---------------------------------------------------------------------------
# 依存: bash 3.2+ / grep / sed / sort のみ。Python・jq は使わない。
#   **唯一の明示的な例外は C2 の `npm audit` である。**
#   依存の既知脆弱性は「既知」であること自体が外部データベースに依存しており、
#   grep で判定できない。したがってここだけ外部コマンドに委ねる。
#   npm が使えない場合は標準出力に `SKIP` を明示し、他の3種の判定は継続する。
#   SKIP を黙って緑にはしない (出力に必ず残す)。
#
# 使い方:
#   scripts/check-catastrophic.sh [SPEC] [ROOT]
#     SPEC  案件の spec.md のパス。省略時は ROOT 配下の `spec.md` を自動探索
#     ROOT  検査対象のルート。省略時はこのスクリプトの1つ上のディレクトリ
#   終了コード:
#     0 = 検出ゼロ
#     1 = 1件以上検出、または保護対象ルート一覧が取れない
#     2 = 前提不成立 (ROOT が存在しない等)
#
# ---------------------------------------------------------------------------
# 【検査する = 4種】
#   C1 シークレット混入
#       秘密鍵ヘッダ / APIキーの形式 / DB接続文字列 / 平文の資格情報の代入
#   C2 依存の既知脆弱性 (CRITICAL・HIGH)
#       `npm audit --audit-level=high`。使えなければ SKIP を出力して続行
#   C3 認証の抜け
#       spec.md 第4節の保護対象ルート一覧を入力に取り、各ルートについて
#       実装側に認証・認可の参照が存在するかを見る
#   C4 注入
#       SQL文字列連結 / eval 系 / シェルコマンドの文字列連結
#
# 【検査しない】
#   上記4種以外のすべて。XSS・CSRF・レート制限・暗号強度・依存の未知脆弱性
#   などは対象外である。本スクリプトが緑であることは「安全」の証明ではなく、
#   「4種の破滅的な形が見当たらない」ことの証明にすぎない。
#
# 【C3 が読む書式 (spec.md 第4節)】
#   第4節の中に「保護対象ルート一覧」という文字列を含む行を置き、
#   その後に **1行1ルート** で列挙する。行の形は次のいずれでもよい。
#     - GET /admin/users
#     - `POST /api/orders`
#     | DELETE | /api/orders/:id | 他人の注文を消せないこと |
#   メソッドの記載が無い行は ANY として扱う。
#   「保護対象ルート一覧」の行が無い場合は、第4節全体からルートを拾う。
#   保護すべきルートが1つも無い案件は、`- NONE` の1行だけを書く (SKIP になる)。
# ============================================================================

set -u

case "${1:-}" in
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_ROOT=$(cd "$SELF_DIR/.." && pwd)

SPEC_ARG=${1:-}
ROOT=${2:-$DEFAULT_ROOT}

if [ ! -d "$ROOT" ]; then
  printf 'FATAL: ROOT が存在しない: %s\n' "$ROOT" >&2
  exit 2
fi
ROOT=$(cd "$ROOT" && pwd)

ERRORS=0
SKIPS=0

err() { # err <file> <line|-> <msg>
  printf 'ERROR %s:%s: %s\n' "$1" "$2" "$3"
  ERRORS=$((ERRORS + 1))
}
info() { printf 'INFO  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; SKIPS=$((SKIPS + 1)); }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/check-catastrophic.XXXXXX") || exit 2
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

BT=$(printf '\140')   # バッククォート (ERE 中に直接書けないため変数で持つ)

# ---------------------------------------------------------------------------
# 走査の対象範囲
#   生成物・依存の取得先・本スクリプト自身を外す。
#   本スクリプト自身を外すのは、検出パターンの文字列そのものが検出されるため。
#   (この自己除外は検査の穴になる。scripts/ 配下は人が読むこと)
# ---------------------------------------------------------------------------
EXC=()
for d in .git node_modules vendor dist build out .next .nuxt target coverage \
         .venv venv __pycache__ .tox .mypy_cache .pytest_cache .gradle Pods \
         .terraform .cache; do
  EXC+=(--exclude-dir="$d")
done
EXC+=(--exclude="check-catastrophic.sh" --exclude="check-test-integrity.sh")
EXC+=(--exclude="*.min.js" --exclude="*.map" --exclude="*.lock")

# C3 の実装側探索では、仕様書・雛形はルートの出現元として数えない
# (spec.md 自身がルート名を含むため、これを実装と誤認すると静かに緑になる)
SRC_EXC=("${EXC[@]}" --exclude-dir=docs --exclude-dir=templates --exclude="*.md")

# report <ラベル> <ERE> <除外ERE(空可)> <検査ID>
#   grep の結果を file:line:内容 で ERROR にする。
report() {
  local label=$1 pat=$2 negpat=$3 id=$4 out="$TMPD/hits"
  : > "$out"
  # 検出パターンは `-` で始まりうる (秘密鍵ヘッダ)。必ず -e で渡す。
  # -e を落とすと grep がパターンをオプションと解釈し、
  # 何も検出せずに静かに緑になる。
  if [ -n "$negpat" ]; then
    grep -rInE -e "$pat" "${EXC[@]}" "$ROOT" 2>/dev/null | grep -Ev -e "$negpat" > "$out" || true
  else
    grep -rInE -e "$pat" "${EXC[@]}" "$ROOT" 2>/dev/null > "$out" || true
  fi
  # grep -r の走査順はディレクトリの読み出し順に依存する。
  # 同じ入力に対して出力を常に同一にするため、パスと行番号で整列する。
  LC_ALL=C sort -t: -k1,1 -k2,2n "$out" -o "$out" 2>/dev/null || true
  local rec f ln body
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    f=${rec%%:*}; rec=${rec#*:}
    ln=${rec%%:*}; body=${rec#*:}
    body=${body#"${body%%[![:space:]]*}"}
    err "${f#$ROOT/}" "$ln" "$id $label: ${body:0:140}"
  done < "$out"
}

# ===========================================================================
# C1 シークレット混入
# ===========================================================================
info "C1 シークレット混入を検査する"

P_PRIVKEY='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
P_APIKEY='(AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
P_DBURL='(postgres|postgresql|mysql|mariadb|mongodb|mongodb\+srv|redis|rediss|amqp|amqps|mssql|jdbc:[a-z0-9]+)://[^[:space:]:@/"'"'"']+:[^[:space:]@"'"'"']+@'
P_PLAINCRED='(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|private[_-]?key|auth[_-]?token|access[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}["'"'"']'
# 環境変数参照・伏字・雛形の穴は除外する (これだけは特異度を上げる。
# 除外しないと環境変数を読む正しい実装がすべて赤になり、出力が読めなくなる)
N_PLACEHOLDER='process\.env|os\.environ|getenv|System\.getenv|ENV\[|\$\{|\$\(|<[A-Za-z_]|xxxx|XXXX|example|EXAMPLE|placeholder|PLACEHOLDER|dummy|DUMMY|changeme|CHANGEME|your[_-]|YOUR[_-]|REDACTED|\*\*\*|\.\.\.'

report "秘密鍵ヘッダ" "$P_PRIVKEY" "" "C1"
report "APIキーの形式" "$P_APIKEY" "" "C1"
report "DB接続文字列 (資格情報を含む)" "$P_DBURL" "" "C1"
report "平文の資格情報の代入" "$P_PLAINCRED" "$N_PLACEHOLDER" "C1"

# ===========================================================================
# C2 依存の既知脆弱性 (CRITICAL・HIGH)
#   bash+grep 原則の唯一の明示的な例外。理由は冒頭の依存の項に書いた。
# ===========================================================================
info "C2 依存の既知脆弱性を検査する"

if [ ! -f "$ROOT/package.json" ]; then
  skip "C2 package.json が無いため npm audit を実行しない (他の3種は継続する)"
elif ! command -v npm >/dev/null 2>&1; then
  skip "C2 npm が使えないため依存の既知脆弱性を検査していない (他の3種は継続する)"
else
  # npm の生出力は自分の出力に混ぜない。
  # npm はエラー時にログファイルのパス (実行時刻を含む) を出すため、
  # そのまま流すと同じ入力でも出力が一致しなくなる。
  # 本スクリプトの出力は、同じ入力に対して常にバイト単位で同一でなければ
  # ならない (赤→緑→赤の実証が成立しなくなるため)。成否だけを見る。
  if ( cd "$ROOT" && npm audit --audit-level=high ) > "$TMPD/audit" 2>&1; then
    info "C2 npm audit: high 以上の既知脆弱性なし"
  else
    if grep -qiE 'ENOLOCK|requires a lockfile|npm error code E|npm ERR! code E' "$TMPD/audit"; then
      skip "C2 npm audit を実行できなかった (lockfile 不在等)。他の3種は継続する"
    else
      err "package.json" "-" "C2 npm audit が high 以上の既知脆弱性を報告した。詳細は 'npm audit --audit-level=high' を手元で実行して読むこと"
    fi
  fi
fi

# ===========================================================================
# C3 認証の抜け
#   spec.md 第4節の「保護対象ルート一覧」を入力に取る。
#   一覧が取れなければ落とす (静かな見逃しの禁止)。
# ===========================================================================
info "C3 認証の抜けを検査する"

SPEC=""
if [ -n "$SPEC_ARG" ]; then
  SPEC=$SPEC_ARG
  case "$SPEC" in /*) ;; *) SPEC="$ROOT/$SPEC" ;; esac
else
  for cand in "$ROOT/spec.md" "$ROOT/docs/spec.md" "$ROOT/doc/spec.md"; do
    [ -f "$cand" ] && SPEC=$cand && break
  done
fi

if [ -z "$SPEC" ] || [ ! -f "$SPEC" ]; then
  err "(spec)" "-" "C3 spec.md が見つからない。保護対象ルート一覧を読めないため検査できない (第1引数でパスを渡す)"
else
  info "C3 spec: ${SPEC#$ROOT/}"
  # --- 第4節を切り出す ---
  : > "$TMPD/sec4"
  in4=0
  while IFS= read -r l || [ -n "$l" ]; do
    if printf '%s' "$l" | grep -Eq '^##[[:space:]]+4[.．]'; then in4=1; continue; fi
    if [ "$in4" -eq 1 ]; then
      if printf '%s' "$l" | grep -Eq '^#{1,2}[[:space:]]'; then break; fi
      printf '%s\n' "$l" >> "$TMPD/sec4"
    fi
  done < "$SPEC"

  if [ ! -s "$TMPD/sec4" ]; then
    err "${SPEC#$ROOT/}" "-" "C3 spec.md 第4節 (見出し ## 4. で始まる節) が無い、または空"
  fi

  # --- 「保護対象ルート一覧」以降に絞る (無ければ第4節全体) ---
  cp "$TMPD/sec4" "$TMPD/listsrc"
  mk=$(grep -n '保護対象ルート一覧' "$TMPD/sec4" | head -n 1 | cut -d: -f1)
  if [ -n "${mk:-}" ]; then
    tail -n +"$((mk + 1))" "$TMPD/sec4" > "$TMPD/listsrc"
  fi

  # --- 1行1ルートとして抽出する ---
  : > "$TMPD/routes"
  while IFS= read -r l || [ -n "$l" ]; do
    # 表の区切り行を捨てる
    printf '%s' "$l" | grep -Eq '^[[:space:]]*\|?[[:space:]]*:?-{3,}' && continue
    # 装飾 (バッククォート / 表の縦棒 / 強調) を空白に潰す
    t=$(printf '%s' "$l" | sed "s/[${BT}|*]/ /g")
    # 箇条書き記号・番号を落とす
    t=$(printf '%s' "$t" | sed -E 's/^[[:space:]]*[-+][[:space:]]+//; s/^[[:space:]]*[0-9]+\.[[:space:]]+//')
    # スラッシュの後に1文字以上を要求する。これが無いと、第4節の散文に含まれる
    # 区切りの「 / 」がルート "/" として拾われ、全ファイルに一致して静かに緑になる。
    route=$(printf '%s' "$t" | grep -Eo '(^|[[:space:]])/[A-Za-z0-9_/:{}.@%*?~+-]+' | head -n 1 | tr -d '[:space:]')
    [ -n "$route" ] || continue
    method=$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//' | grep -Eo '^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|ANY)' | head -n 1)
    [ -n "$method" ] || method=ANY
    printf '%s %s\n' "$method" "$route" >> "$TMPD/routes"
  done < "$TMPD/listsrc"
  sort -u "$TMPD/routes" -o "$TMPD/routes"

  if [ ! -s "$TMPD/routes" ]; then
    if grep -Eq '^[[:space:]]*[-*+]?[[:space:]]*NONE[[:space:]]*$' "$TMPD/listsrc"; then
      # 「認証を持つルートは無い」と明示的に宣言された状態。C2 と同じ扱いにする。
      # ここを ERROR にすると、認証を持たない案件 (静的サイト・読み取り専用の
      # 社内ツール等) で C3 が恒久的に赤になり、検査そのものを外す動機を作る。
      # それは D-20260825-18 が名指しした「無効化の温床」であり、
      # 検査を守るはずの設計が検査を殺す。
      # ただし緑にもしない。SKIP を出力に必ず残す。
      skip "C3 保護対象ルート一覧が NONE と宣言されている。認証の抜けを検査していない (他の3種は継続する)"
    else
      # 書き忘れと、意図した宣言は別物である。何も書いていない場合は落とす。
      err "${SPEC#$ROOT/}" "-" "C3 保護対象ルート一覧が空、または1行1ルートの形で読めない。宣言が無いので緑にしない (該当が無いなら - NONE と明示する)"
    fi
  else
    n=$(grep -c '' "$TMPD/routes" | tr -d '[:space:]')
    info "C3 保護対象ルート: ${n} 件"
    AUTH_RE='auth|login|logout|session|token|jwt|guard|permission|policy|role|current[_-]?user|middleware|forbidden|unauthorized|401|403'
    while IFS= read -r row || [ -n "$row" ]; do
      [ -n "$row" ] || continue
      m=${row%% *}
      r=${row#* }
      # 動的セグメントの手前までを実装探索の手掛かりにする
      stem=$(printf '%s' "$r" | sed -E 's/[:{*?].*$//; s#/+$##')
      [ -n "$stem" ] || stem=$r
      grep -rlIF -e "$stem" "${SRC_EXC[@]}" "$ROOT" 2>/dev/null | sort -u > "$TMPD/rfiles" || true
      if [ ! -s "$TMPD/rfiles" ]; then
        err "${SPEC#$ROOT/}" "-" "C3 保護対象ルート $m $r の実装が見当たらない (手掛かり: '$stem')。検査できないので緑にしない"
        continue
      fi
      hit=""
      while IFS= read -r sf || [ -n "$sf" ]; do
        [ -n "$sf" ] || continue
        if grep -qiE -e "$AUTH_RE" "$sf" 2>/dev/null; then hit=$sf; break; fi
      done < "$TMPD/rfiles"
      if [ -z "$hit" ]; then
        first=$(head -n 1 "$TMPD/rfiles")
        err "${first#$ROOT/}" "-" "C3 保護対象ルート $m $r に認証・認可の参照が無い"
      else
        printf 'OK    C3 %s %s (認証・認可の参照: %s)\n' "$m" "$r" "${hit#$ROOT/}"
      fi
    done < "$TMPD/routes"
  fi
fi

# ===========================================================================
# C4 注入
# ===========================================================================
info "C4 注入を検査する"

SQLKW='SELECT|INSERT|UPDATE|DELETE|WHERE|FROM|VALUES|DROP[[:space:]]+TABLE'
P_SQL_CONCAT="\"[^\"]*(${SQLKW})[^\"]*\"[[:space:]]*\\+|'[^']*(${SQLKW})[^']*'[[:space:]]*\\+"
P_SQL_INTERP="${BT}[^${BT}]*(${SQLKW})[^${BT}]*\\\$\\{|f\"[^\"]*(${SQLKW})[^\"]*\\{|f'[^']*(${SQLKW})[^']*\\{|\"[^\"]*(${SQLKW})[^\"]*\"[[:space:]]*(%|\\.[[:space:]]*format[[:space:]]*\\()"
P_EVAL='(^|[^A-Za-z0-9_.$])eval[[:space:]]*\(|new[[:space:]]+Function[[:space:]]*\(|(^|[^A-Za-z0-9_.])exec[[:space:]]*\(|Runtime\.getRuntime\(\)\.exec|assert[[:space:]]*\([[:space:]]*eval'
P_SHELL="(os\\.system|shell_exec|passthru|proc_open|popen|subprocess\\.(run|call|check_call|check_output|Popen)|child_process|execSync|spawnSync|(^|[^A-Za-z0-9_.])(exec|spawn)[[:space:]]*\\()[^;]*(\\+[[:space:]]*[A-Za-z_\$]|\\\$\\{|%s|\\.format\\(|f[\"'])|shell[[:space:]]*=[[:space:]]*True"

report "SQL文字列の連結" "$P_SQL_CONCAT" "" "C4"
report "SQL文字列への値の埋め込み" "$P_SQL_INTERP" "" "C4"
report "eval 系の実行" "$P_EVAL" "" "C4"
report "シェルコマンドの文字列連結" "$P_SHELL" "" "C4"

# ===========================================================================
# 集計
# ===========================================================================
printf -- '---\n'
printf 'root: %s\n' "$ROOT"
printf 'ERROR: %d / SKIP: %d\n' "$ERRORS" "$SKIPS"
if [ "$ERRORS" -gt 0 ]; then
  printf 'RESULT: FAIL (検出ゼロ以外は落とす。誤検知は想定内であり、緩和しない)\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
