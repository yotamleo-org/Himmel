import { writeFile } from "node:fs/promises";
import { basename } from "node:path";

const API = (t: string, m: string) => `https://api.telegram.org/bot${t}/${m}`;
type F = typeof fetch;
// A non-ok response (e.g. a Telegram-API-side Bad Gateway storm)
// THROWS instead of returning []. poller.ts's main loop already wraps getUpdates
// in a try/catch for network errors; folding the API-level failure into that same
// path lets it back off instead of hot-looping with zero delay, which is what a
// silent [] used to produce. An ok:true call still never throws (below) — that
// path stays fail-open for a malformed result array.
//
// Client-side abort deadline.
// `timeout` above is only a QUERY PARAMETER telling Telegram how long to hold the
// connection open server-side; it does NOT bound the fetch itself. Without a
// client-side abort, a stalled transport (or a response whose body never
// completes) left `await f(...)` / `await res.json()` pending forever — no
// reject, so the catch/backoff above (and the outage marker) never
// fired, and the bridge went silently deaf while the process stayed alive and
// the supervisor saw nothing wrong. The deadline is set slightly LONGER than the
// server-side long-poll timeout, so a healthy long poll — which returns at or
// before `timeout` seconds, whether from an update arriving or Telegram's own
// timeout — is never cut short. Per the WHATWG fetch spec, aborting a signal
// aborts BOTH the in-flight request and, once headers have arrived, the response
// body stream, so this one signal covers res.json() too — the same pattern
// getFile/downloadFile below already use for FILE_FETCH_TIMEOUT_MS.
const GETUPDATES_ABORT_MARGIN_MS = 10_000;
export async function getUpdates(token: string, offset: number, timeout = 30, f: F = fetch, abortMarginMs = GETUPDATES_ABORT_MARGIN_MS): Promise<any[]> {
  const res = await f(API(token, "getUpdates") + `?offset=${offset}&timeout=${timeout}`,
    { signal: AbortSignal.timeout(timeout * 1000 + abortMarginMs) });
  const j: any = await res.json();
  if (!j.ok) throw new Error(`getUpdates not ok: ${j.description ?? res.status}`);
  return j.result ?? [];   // tolerate a malformed ok:true with no result array (never throw downstream)
}
// Resolve the bridge's own bot username (LUNA-158): the require-mention gate
// needs it to recognize `@<botusername>` in group text. Best-effort — null on
// any failure (network, non-ok, malformed result), so the caller can fail
// open rather than the whole bridge refusing to start over a transient
// getMe hiccup.
export async function getMe(token: string, f: F = fetch): Promise<string | null> {
  try {
    const res = await f(API(token, "getMe"), { signal: AbortSignal.timeout(10_000) });
    const j: any = await res.json().catch(() => ({}));
    if (!j.ok || typeof j.result?.username !== "string") return null;
    return j.result.username;
  } catch { return null; }
}
// Best-effort "typing…" indicator. No retries, failures swallowed —
// a missed indicator is harmless; it must never disturb the poll loop.
export async function sendChatAction(token: string, chat_id: number, f: F = fetch): Promise<void> {
  try {
    await f(API(token, "sendChatAction"), { method: "POST",
      headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id, action: "typing" }) });
  } catch {}
}

// Best-effort ack of an inline-button tap (stops the client spinner, may show a
// toast). No retries, failures swallowed, like sendChatAction.
export async function answerCallbackQuery(token: string, callback_query_id: string, text: string, f: F = fetch): Promise<void> {
  try {
    await f(API(token, "answerCallbackQuery"), { method: "POST",
      headers: { "content-type": "application/json" }, body: JSON.stringify({ callback_query_id, text }) });
  } catch {}
}

// Redact chat_id for logs (CR public-474): it's a stable user/group identifier
// and these logs get captured into session notes committed to a vault. For
// longer ids, keeps the last 2 digits so repeated failures for the same chat
// can still be correlated without exposing the raw id.
export const redactChatId = (chat_id: number): string => {
  const digits = String(chat_id).replace(/^-/, "");
  return digits.length > 2 ? `***${digits.slice(-2)}` : "***";
};

// Returns whether Telegram actually ACCEPTED the message — the HTTP request
// succeeded AND the Bot API JSON reports `ok: true` (same success signal
// getUpdates/getFile validate; an HTTP 200 with `{ ok: false }` is NOT a
// delivery). A permanent 4xx drop or retry-exhaustion returns false rather
// than throwing, so best-effort callers can ignore it while a caller that must
// know delivery happened (e.g. luna-sync-alert's cooldown state) can gate on it.

export async function sendMessage(token: string, chat_id: number, text: string,
    f: F = fetch, sleep: (ms:number)=>Promise<void> = (ms)=>Bun.sleep(ms), receipt?: (messageId: number) => void, replyToMessageId?: number, replyMarkup?: object): Promise<boolean> {
  for (let attempt = 0; attempt < 5; attempt++) {
    let res: Response;
    try {
      res = await f(API(token, "sendMessage"), { method: "POST",
        headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id, text, ...(Number.isSafeInteger(replyToMessageId) && replyToMessageId! > 0 ? { reply_parameters: { message_id: replyToMessageId, allow_sending_without_reply: true } } : {}), ...(replyMarkup ? { reply_markup: replyMarkup } : {}) }) });
    } catch {
      // A lost response is indistinguishable from a failed send; retrying can duplicate alerts.
      console.error(`[telegram] sendMessage transport failure chat=${redactChatId(chat_id)}`);
      return false;
    }
    const j: any = await res.json().catch(() => ({}));
    if (res.ok && j?.ok === true) {
      if (Number.isSafeInteger(j.result?.message_id) && j.result.message_id > 0) receipt?.(j.result.message_id);
      return true;
    }
    if (res.status === 429) { if (attempt < 4) await sleep((j?.parameters?.retry_after ?? 1) * 1000); continue; }
    if (res.status >= 400 && res.status < 500) {           // permanent client error → log + drop (never loop)
      console.error(`[telegram] sendMessage ${res.status} chat=${redactChatId(chat_id)}: ${j?.description ?? ""}`);
      return false;
    }
    if (attempt < 4) await sleep(1000);                      // transient 5xx (or 2xx ok:false) → bounded retry (skip on last attempt — no retry follows)
  }
  console.error(`[telegram] sendMessage gave up after retries chat=${redactChatId(chat_id)}`);
  return false;
}
// Send a local file as a document (multipart; any file type, the Bot
// API caps uploads at 50 MB — the caller refuses an oversize file before it gets here).
// Same contract as sendMessage: true only on a Bot API ok:true, a permanent 4xx or
// retry exhaustion returns false, a lost response is NOT retried (it would duplicate).
const DOC_UPLOAD_TIMEOUT_MS = 120_000;
export async function sendDocument(token: string, chat_id: number, path: string, caption?: string,
    f: F = fetch, sleep: (ms:number)=>Promise<void> = (ms)=>Bun.sleep(ms), receipt?: (messageId: number) => void): Promise<boolean> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const form = new FormData();
    form.set("chat_id", String(chat_id));
    if (caption) form.set("caption", caption.slice(0, 1024));   // Bot API caption limit
    form.set("document", new File([await Bun.file(path).arrayBuffer()], basename(path)));   // BunFile ignores the filename arg
    let res: Response;
    try {
      res = await f(API(token, "sendDocument"), { method: "POST", body: form, signal: AbortSignal.timeout(DOC_UPLOAD_TIMEOUT_MS) });
    } catch {
      console.error(`[telegram] sendDocument transport failure chat=${redactChatId(chat_id)}`);
      return false;
    }
    const j: any = await res.json().catch(() => ({}));
    if (res.ok && j?.ok === true) {
      if (Number.isSafeInteger(j.result?.message_id) && j.result.message_id > 0) receipt?.(j.result.message_id);
      return true;
    }
    if (res.status === 429) { if (attempt < 4) await sleep((j?.parameters?.retry_after ?? 1) * 1000); continue; }
    if (res.status >= 400 && res.status < 500) {
      console.error(`[telegram] sendDocument ${res.status} chat=${redactChatId(chat_id)}: ${j?.description ?? ""}`);
      return false;
    }
    if (attempt < 4) await sleep(1000);
  }
  console.error(`[telegram] sendDocument gave up after retries chat=${redactChatId(chat_id)}`);
  return false;
}
// Bound on file-fetch calls: unlike getUpdates (long-poll bounds itself), a hung
// getFile/download would stall the single-threaded ingest loop indefinitely (CR).
const FILE_FETCH_TIMEOUT_MS = 30_000;
// Resolve a file_id to its server-side file_path. Null on any
// failure — caller decides whether to forward the message without the file.
export async function getFile(token: string, file_id: string, f: F = fetch): Promise<string | null> {
  const res = await f(API(token, "getFile") + `?file_id=${encodeURIComponent(file_id)}`, { signal: AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS) });
  const j: any = await res.json().catch(() => ({}));
  if (!j.ok || !j.result?.file_path) { console.error(`[telegram] getFile not ok: ${j.description ?? res.status}`); return null; }
  return j.result.file_path;
}
// Download a resolved file_path to dest. False on failure (logged, never throws —
// a write error must degrade to caption-only forwarding, not bubble into ingest).
export async function downloadFile(token: string, file_path: string, dest: string, f: F = fetch): Promise<boolean> {
  try {
    const res = await f(`https://api.telegram.org/file/bot${token}/${file_path}`, { signal: AbortSignal.timeout(FILE_FETCH_TIMEOUT_MS) });
    if (!res.ok) { console.error(`[telegram] file download ${res.status} for ${file_path}`); return false; }
    await writeFile(dest, Buffer.from(await res.arrayBuffer()));
    return true;
  } catch (e) { console.error(`[telegram] file download failed for ${file_path}: ${e}`); return false; }
}
