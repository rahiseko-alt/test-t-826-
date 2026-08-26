/**
 * acceptance.spec.ts — 受入検査（E2E）の雛形
 *
 * 設計の正は docs/discussions/D-20260825-18-test-layer-design.md 第4節。
 * 転写の手順は同じディレクトリの README.md に書いてある。
 *
 * -------------------------------------------------------------------------
 * 構成（1回のブラウザ起動に束ねる）
 *
 *   順 | 内容                                   | 落ちたとき
 *   ---+----------------------------------------+--------------------------
 *   ①  | ハッピーパス1周                        | 即終了。以降を走らせない
 *   ②  | 画面への引っ掛け（代表数件）           | 記録して続行
 *   ③  | API層への引っ掛け（数百件・ブラウザ外） | 記録して続行
 *   ④  | 2周目（状態が残っていないか）          | 記録
 *   ⑤  | 権限（未ログイン／他人として到達可か）  | 記録
 *   ⑥  | 記録の集計                             | 1件でもあれば落とす
 *
 * ①だけが fail-fast である。test.describe.serial は前のテストが落ちると
 * 以降を走らせないため、①が投げれば②以降は実行されない。
 * ②〜⑤は「記録して続行」なので、その場では投げずに findings に積み、
 * 最後の⑥でまとめて落とす。
 *
 * -------------------------------------------------------------------------
 * 引っ掛け値は人もAIも書かない（D-20260825-18 第4節）
 *
 * このファイルには引っ掛け値の一覧が存在しない。すべて seed から機械生成する。
 * 理由は2つ。
 *   1. 人が書くと、書ける範囲しか試せない
 *   2. 一覧を人が持つと静かに短くできる。生成なら短くする対象が存在しない
 * したがって、このファイルに値の配列を書き足してはいけない。
 * 検査を強めたいときは HOOK_SEED を変えるか、件数を増やす。
 *
 * -------------------------------------------------------------------------
 * 環境変数
 *   BASE_URL         検査対象の URL（既定 http://localhost:3000）
 *   SPEC_PATH        案件の spec.md のパス（既定 <cwd>/spec.md）
 *   HOOK_SEED        引っ掛け値の seed。整数（既定 20260825）
 *   UI_HOOK_COUNT    ②の件数（既定 5）
 *   API_HOOK_COUNT   ③の件数（既定 300）
 *   LOGIN_ID / LOGIN_PW            ①④で使う資格情報
 *   OTHER_LOGIN_ID / OTHER_LOGIN_PW ⑤「他人として」で使う別人の資格情報
 */

import {
  test,
  expect,
  request as apiRequest,
  type APIRequestContext,
  type BrowserContext,
  type Page,
} from '@playwright/test';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

// ===========================================================================
// 設定
// ===========================================================================

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:3000';
const SPEC_PATH = process.env.SPEC_PATH ?? resolve(process.cwd(), 'spec.md');
const HOOK_SEED = Number.parseInt(process.env.HOOK_SEED ?? '20260825', 10);
const UI_HOOK_COUNT = Number.parseInt(process.env.UI_HOOK_COUNT ?? '5', 10);
const API_HOOK_COUNT = Number.parseInt(process.env.API_HOOK_COUNT ?? '300', 10);

const LOGIN_ID = process.env.LOGIN_ID ?? '';
const LOGIN_PW = process.env.LOGIN_PW ?? '';
const OTHER_LOGIN_ID = process.env.OTHER_LOGIN_ID ?? '';
const OTHER_LOGIN_PW = process.env.OTHER_LOGIN_PW ?? '';

// ===========================================================================
// 記録（②〜⑤は投げずにここへ積む）
// ===========================================================================

type Finding = { phase: string; detail: string };
const findings: Finding[] = [];
function record(phase: string, detail: string): void {
  findings.push({ phase, detail });
}
function describeError(e: unknown): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : String(e);
}

// ===========================================================================
// 引っ掛け値の生成器
//
// 値の一覧は持たない。seed から決まる擬似乱数で、
//   - 符号位置の範囲（制御文字帯／ASCII／ラテン拡張／かな／漢字／追加多言語面）
//   - 長さの階級（0／1／中間／境界付近／極端に長い）
//   - 数値の桁・符号・小数・指数（停止4領域の「金額」に対応）
//   - 年月日の値域外（停止4領域の「日付」に対応）
// を算術で組み立てる。ここに配列リテラルを足してはいけない。
// ===========================================================================

/** seed から決まる擬似乱数列（mulberry32）。同じ seed なら同じ列になる。 */
function makeRng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pickInt(rng: () => number, min: number, max: number): number {
  return min + Math.floor(rng() * (max - min + 1));
}

/** 符号位置を、帯を選んでから範囲内で引く。帯そのものが値の一覧ではない。 */
function pickCodePoint(rng: () => number): number {
  switch (pickInt(rng, 0, 6)) {
    case 0:
      return pickInt(rng, 0x09, 0x1f); // 制御文字帯（改行・タブを含む）
    case 1:
      return pickInt(rng, 0x21, 0x2f); // 記号帯（引用符・不等号・百分率など）
    case 2:
      return pickInt(rng, 0x30, 0x7e); // ASCII 英数記号帯
    case 3:
      return pickInt(rng, 0x80, 0x24f); // ラテン拡張帯
    case 4:
      return pickInt(rng, 0x3040, 0x30ff); // かな帯
    case 5:
      return pickInt(rng, 0x4e00, 0x9fff); // 漢字帯
    default:
      return pickInt(rng, 0x1f300, 0x1faff); // 追加多言語面（サロゲートペア）
  }
}

/** 長さの階級。境界（0・1・上限付近・極端に長い）を算術で出す。 */
function pickLength(rng: () => number): number {
  switch (pickInt(rng, 0, 4)) {
    case 0:
      return 0;
    case 1:
      return 1;
    case 2:
      return pickInt(rng, 2, 64);
    case 3:
      return pickInt(rng, 250, 260); // 桁上がりが起きやすい境界の付近
    default:
      return pickInt(rng, 4096, 16384); // 極端に長い
  }
}

function randomText(rng: () => number): string {
  const len = pickLength(rng);
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCodePoint(pickCodePoint(rng));
  return s;
}

/** 停止4領域の「金額」に対応する。桁・符号・小数・指数・空白を算術で組む。 */
function randomNumberText(rng: () => number): string {
  const sign = pickInt(rng, 0, 3) === 0 ? '-' : '';
  const intDigits = pickInt(rng, 0, 24);
  let head = '';
  for (let i = 0; i < intDigits; i++) head += String(pickInt(rng, 0, 9));
  if (head === '') head = String(pickInt(rng, 0, 9));
  let frac = '';
  if (pickInt(rng, 0, 2) === 0) {
    const fracDigits = pickInt(rng, 1, 12);
    frac = '.';
    for (let i = 0; i < fracDigits; i++) frac += String(pickInt(rng, 0, 9));
  }
  const exp = pickInt(rng, 0, 5) === 0 ? `e${pickInt(rng, -40, 40)}` : '';
  const pad = pickInt(rng, 0, 4) === 0 ? ' '.repeat(pickInt(rng, 1, 3)) : '';
  return `${pad}${sign}${head}${frac}${exp}${pad}`;
}

/** 停止4領域の「日付」に対応する。値域外の年月日を算術で作る。 */
function randomDateText(rng: () => number): string {
  const y = pickInt(rng, -1, 10000);
  const m = pickInt(rng, 0, 13);
  const d = pickInt(rng, 0, 32);
  const hh = pickInt(rng, -1, 25);
  const mi = pickInt(rng, -1, 61);
  const pad2 = (n: number) => (n < 0 ? String(n) : String(n).padStart(2, '0'));
  switch (pickInt(rng, 0, 3)) {
    case 0:
      return `${y}-${pad2(m)}-${pad2(d)}`;
    case 1:
      return `${y}-${pad2(m)}-${pad2(d)}T${pad2(hh)}:${pad2(mi)}:00Z`;
    case 2:
      return `${pad2(d)}/${pad2(m)}/${y}`;
    default:
      return String(pickInt(rng, -8640000000000, 8640000000000)); // 通算ミリ秒
  }
}

/** 記号で包んだ構造。包む記号も符号位置の算術で選ぶ。 */
function randomStructured(rng: () => number): string {
  const open = String.fromCodePoint(pickInt(rng, 0x21, 0x2f));
  const close = String.fromCodePoint(pickInt(rng, 0x3a, 0x40));
  const repeat = pickInt(rng, 1, 8);
  let body = '';
  for (let i = 0; i < repeat; i++) body += randomText(makeRng(pickInt(rng, 0, 2 ** 30)));
  return open.repeat(repeat) + body + close.repeat(repeat);
}

/** seed と通番から1件の引っ掛け値を作る。同じ入力なら必ず同じ値になる。 */
export function hookValue(seed: number, index: number): string {
  const rng = makeRng((seed + Math.imul(index, 2654435761)) >>> 0);
  switch (pickInt(rng, 0, 3)) {
    case 0:
      return randomText(rng);
    case 1:
      return randomNumberText(rng);
    case 2:
      return randomDateText(rng);
    default:
      return randomStructured(rng);
  }
}

// ===========================================================================
// spec.md 第4節「保護対象ルート一覧」の読み取り
//   書式は scripts/check-catastrophic.sh と同じ。1行1ルート。
//   読めない・空なら、それ自体を findings に積む（静かに緑にしない）。
// ===========================================================================

export type ProtectedRoute = { method: string; path: string };

export function readProtectedRoutes(specPath: string): ProtectedRoute[] {
  if (!existsSync(specPath)) return [];
  const lines = readFileSync(specPath, 'utf8').split(/\r?\n/);

  // 第4節を切り出す
  const body: string[] = [];
  let inSection4 = false;
  for (const line of lines) {
    if (/^##\s+4[.．]/.test(line)) {
      inSection4 = true;
      continue;
    }
    if (inSection4) {
      if (/^#{1,2}\s/.test(line)) break;
      body.push(line);
    }
  }

  // 「保護対象ルート一覧」の行があれば、それ以降に絞る
  const markerAt = body.findIndex((l) => l.includes('保護対象ルート一覧'));
  const source = markerAt >= 0 ? body.slice(markerAt + 1) : body;

  const out: ProtectedRoute[] = [];
  const seen = new Set<string>();
  for (const raw of source) {
    if (/^\s*\|?\s*:?-{3,}/.test(raw)) continue; // 表の区切り行
    const t = raw
      .replace(/[`|*]/g, ' ')
      .replace(/^\s*[-+]\s+/, '')
      .replace(/^\s*\d+\.\s+/, '');
    const m = t.match(/(?:^|\s)(\/[A-Za-z0-9_/:{}.@%*?~+-]+)/);
    if (!m) continue;
    const methodMatch = t
      .trim()
      .match(/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|ANY)\b/);
    const route = { method: methodMatch ? methodMatch[1] : 'ANY', path: m[1] };
    const key = `${route.method} ${route.path}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(route);
  }
  return out;
}

/** 500番台・スタックトレース・内部エラーの露出を「落ちた」とみなす手掛かり */
const CRASH_HINT =
  /(Internal Server Error|Traceback \(most recent call last\)|at Object\.<anonymous>|Unhandled|NullPointerException|panic:|内部エラー|500 -)/;

// ===========================================================================
// 検査本体
// ===========================================================================

let context: BrowserContext;
let page: Page;
let api: APIRequestContext;

test.describe.serial('受入検査（1回のブラウザ起動に束ねる）', () => {
  test.beforeAll(async ({ browser }) => {
    // ブラウザ起動は1回だけ。以降のテストは同じ context / page を使い回す。
    context = await browser.newContext({ baseURL: BASE_URL });
    page = await context.newPage();
    // ③はブラウザを通さない。APIRequestContext を別に持つ。
    api = await apiRequest.newContext({ baseURL: BASE_URL });
  });

  test.afterAll(async () => {
    await api?.dispose();
    await context?.close();
  });

  // -------------------------------------------------------------------------
  // ① ハッピーパス1周（落ちたら即終了。以降を走らせない）
  //
  // ここは spec.md 第2節の検収条件（Given-When-Then）をそのまま転写する。
  // 手順を減らすと scripts/check-test-integrity.sh の T5 が spec.md 側の
  // 減少を検出する。逆に、ここを減らして spec.md を残した場合は検出されない。
  // 手順の数は spec.md と一致させること。
  // -------------------------------------------------------------------------
  test('① ハッピーパス1周', async () => {
    // [転写1] spec.md 第2節 Given — 前提の準備（ログイン・初期データ）
    await page.goto('/');
    if (LOGIN_ID !== '') {
      await page.getByLabel('ID').fill(LOGIN_ID);
      await page.getByLabel('パスワード').fill(LOGIN_PW);
      await page.getByRole('button', { name: 'ログイン' }).click();
    }
    // [転写1 ここまで]

    // [転写2] spec.md 第2節 When — 操作（URL到達から最終出力までの通し操作）
    await page.getByRole('link', { name: '新規作成' }).click();
    await page.getByLabel('件名').fill('受入検査');
    await page.getByRole('button', { name: '保存' }).click();
    // [転写2 ここまで]

    // [転写3] spec.md 第2節 Then — 期待される最終出力
    await expect(page.getByText('保存しました')).toBeVisible();
    // [転写3 ここまで]
  });

  // -------------------------------------------------------------------------
  // ② 画面への引っ掛け（代表数件）— 記録して続行
  // -------------------------------------------------------------------------
  test('② 画面への引っ掛け', async () => {
    for (let i = 0; i < UI_HOOK_COUNT; i++) {
      const value = hookValue(HOOK_SEED, i);
      try {
        // [転写4] 画面の入力欄と送信ボタン（①の When と同じ経路を使う）
        await page.goto('/');
        await page.getByRole('link', { name: '新規作成' }).click();
        await page.getByLabel('件名').fill(value);
        await page.getByRole('button', { name: '保存' }).click();
        // [転写4 ここまで]

        const html = await page.content();
        if (CRASH_HINT.test(html)) {
          record('②', `#${i} 内部エラーが画面に出た: ${JSON.stringify(value.slice(0, 60))}`);
        }
      } catch (e) {
        record('②', `#${i} 操作が続行不能になった: ${describeError(e)}`);
      }
    }
  });

  // -------------------------------------------------------------------------
  // ③ API層への引っ掛け（数百件・ブラウザを通さない）— 記録して続行
  //   1件あたりの費用が小さいので、予算のほぼ全部をここに使う。
  // -------------------------------------------------------------------------
  test('③ API層への引っ掛け', async () => {
    for (let i = 0; i < API_HOOK_COUNT; i++) {
      const value = hookValue(HOOK_SEED, 1000 + i);
      try {
        // [転写5] API層の入口（ブラウザを通さない。①の When に対応する API）
        const res = await api.post('/api/items', { data: { title: value } });
        // [転写5 ここまで]

        const status = res.status();
        if (status >= 500) {
          record('③', `#${i} status=${status} 入力: ${JSON.stringify(value.slice(0, 60))}`);
          continue;
        }
        const text = await res.text();
        if (CRASH_HINT.test(text)) {
          record('③', `#${i} 応答に内部エラーが露出した: ${text.slice(0, 120)}`);
        }
      } catch (e) {
        record('③', `#${i} 要求そのものが失敗した: ${describeError(e)}`);
      }
    }
  });

  // -------------------------------------------------------------------------
  // ④ 2周目（状態が残っていないか）— 記録
  //   ①と同じ手順を同じ session でもう一度行う。1周目の状態が残っていると
  //   ここで落ちる（「2回目にだけ壊れる」型を捕まえる）。
  // -------------------------------------------------------------------------
  test('④ 2周目', async () => {
    try {
      // [転写2 の再掲] ①の When と Then をそのまま繰り返す
      await page.goto('/');
      await page.getByRole('link', { name: '新規作成' }).click();
      await page.getByLabel('件名').fill('受入検査（2周目）');
      await page.getByRole('button', { name: '保存' }).click();
      await expect(page.getByText('保存しました')).toBeVisible({ timeout: 10_000 });
      // [転写2 の再掲 ここまで]
    } catch (e) {
      record('④', `2周目が完了しなかった（1周目の状態が残っている疑い）: ${describeError(e)}`);
    }
  });

  // -------------------------------------------------------------------------
  // ⑤ 権限（未ログイン／他人として到達できないか）— 記録
  //   検査対象は spec.md 第4節の保護対象ルート一覧。ここに列挙されたものを
  //   回す。一覧が読めない・空であること自体を記録する（静かに緑にしない）。
  // -------------------------------------------------------------------------
  test('⑤ 権限', async () => {
    const routes = readProtectedRoutes(SPEC_PATH);
    if (routes.length === 0) {
      record(
        '⑤',
        `spec.md 第4節の保護対象ルート一覧が読めない、または空: ${SPEC_PATH}。検査対象が不明なので緑にしない`,
      );
      return;
    }

    // --- 未ログイン（資格情報を1つも持たない文脈） ---
    const anonymous = await apiRequest.newContext({ baseURL: BASE_URL });
    try {
      for (const route of routes) {
        const method = route.method === 'ANY' ? 'GET' : route.method;
        try {
          const res = await anonymous.fetch(route.path, {
            method,
            failOnStatusCode: false,
            maxRedirects: 0,
          });
          const status = res.status();
          const blocked = status === 401 || status === 403 || (status >= 300 && status < 400);
          if (!blocked && status < 400) {
            record('⑤', `未ログインで ${method} ${route.path} に到達できた (status=${status})`);
          }
        } catch (e) {
          record('⑤', `未ログインでの ${method} ${route.path} の検査が失敗した: ${describeError(e)}`);
        }
      }
    } finally {
      await anonymous.dispose();
    }

    // --- 他人として（別人の資格情報でログインした文脈） ---
    if (OTHER_LOGIN_ID === '') {
      record('⑤', '他人としての到達を検査していない（OTHER_LOGIN_ID が未設定）');
      return;
    }
    const otherContext = await context.browser()!.newContext({ baseURL: BASE_URL });
    const otherPage = await otherContext.newPage();
    try {
      // [転写6] 別人としてのログイン手順
      await otherPage.goto('/');
      await otherPage.getByLabel('ID').fill(OTHER_LOGIN_ID);
      await otherPage.getByLabel('パスワード').fill(OTHER_LOGIN_PW);
      await otherPage.getByRole('button', { name: 'ログイン' }).click();
      // [転写6 ここまで]

      for (const route of routes) {
        const method = route.method === 'ANY' ? 'GET' : route.method;
        try {
          const res = await otherContext.request.fetch(route.path, {
            method,
            failOnStatusCode: false,
            maxRedirects: 0,
          });
          const status = res.status();
          if (status < 400 && status < 300) {
            record('⑤', `他人として ${method} ${route.path} に到達できた (status=${status})`);
          }
        } catch (e) {
          record('⑤', `他人としての ${method} ${route.path} の検査が失敗した: ${describeError(e)}`);
        }
      }
    } finally {
      await otherContext.close();
    }
  });

  // -------------------------------------------------------------------------
  // ⑥ 記録の集計 — ②〜⑤で積んだものを、ここでまとめて落とす
  // -------------------------------------------------------------------------
  test('⑥ 記録の集計', async () => {
    if (findings.length === 0) return;
    const lines = findings.map((f, i) => `${i + 1}. [${f.phase}] ${f.detail}`);
    throw new Error(
      `引っ掛け・2周目・権限で ${findings.length} 件を記録した（seed=${HOOK_SEED}）:\n` +
        lines.join('\n'),
    );
  });
});
