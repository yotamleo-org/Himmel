import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { PeerTelegram, RetryAfter, TelegramError } from "./telegram";

const TOKEN = "1234567890:" + "T".repeat(35);

type Call = { url: string; body: any };
function stub(reply: (url: string, body: any) => { status?: number; json: any } | Error) {
  const calls: Call[] = [];
  const f = (async (url: string, init?: RequestInit) => {
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ url, body });
    const r = reply(url, body);
    if (r instanceof Error) throw r;
    return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
  }) as unknown as typeof fetch;
  return { f, calls };
}

test("sendMessage posts plain text with previews off and no parse_mode", async () => {
  const { f, calls } = stub(() => ({ json: { ok: true, result: { message_id: 77 } } }));
  const tg = new PeerTelegram(TOKEN, f);
  const res = await tg.sendMessage(-100123, "hello", 12);
  expect(res.message_id).toBe(77);
  expect(calls[0].url).toBe(`https://api.telegram.org/bot${TOKEN}/sendMessage`);
  expect(calls[0].body.link_preview_options).toEqual({ is_disabled: true });
  expect("parse_mode" in calls[0].body).toBe(false);
  expect(calls[0].body.reply_parameters).toEqual({ message_id: 12 });
  expect(calls[0].body.chat_id).toBe(-100123);
});

test("a root send has no reply_parameters", async () => {
  const { f, calls } = stub(() => ({ json: { ok: true, result: { message_id: 1 } } }));
  await new PeerTelegram(TOKEN, f).sendMessage(-1, "x");
  expect("reply_parameters" in calls[0].body).toBe(false);
});

test("a 429 throws RetryAfter with the seconds", async () => {
  const { f } = stub(() => ({ status: 429, json: { ok: false, error_code: 429, description: "Too Many Requests", parameters: { retry_after: 7 } } }));
  const err = await new PeerTelegram(TOKEN, f).sendMessage(-1, "x").catch(e => e);
  expect(err).toBeInstanceOf(RetryAfter);
  expect(err.seconds).toBe(7);
});

test("a 5xx and an ok:false throw TelegramError carrying the code and parameters", async () => {
  const { f } = stub(() => ({ status: 400, json: { ok: false, error_code: 400, description: "Bad Request: group chat was upgraded to a supergroup chat", parameters: { migrate_to_chat_id: -100999 } } }));
  const err = await new PeerTelegram(TOKEN, f).getChat(-5).catch(e => e);
  expect(err).toBeInstanceOf(TelegramError);
  expect(err.code).toBe(400);
  expect(err.parameters.migrate_to_chat_id).toBe(-100999);
  const s5 = stub(() => ({ status: 502, json: "<html>" }));
  const e5 = await new PeerTelegram(TOKEN, s5.f).getUpdates(0, 0).catch(e => e);
  expect(e5).toBeInstanceOf(TelegramError);
  expect(e5.code).toBe(502);
});

test("the token never appears in a thrown message", async () => {
  const net = stub(url => new Error(`connect failed for ${url}`));
  const err = await new PeerTelegram(TOKEN, net.f).sendMessage(-1, "x").catch(e => e);
  expect(String(err.message)).not.toContain(TOKEN);
  expect(String(err.message)).not.toContain(TOKEN.split(":")[1]);
  const api = stub(() => ({ status: 401, json: { ok: false, error_code: 401, description: `Unauthorized ${TOKEN}` } }));
  const e2 = await new PeerTelegram(TOKEN, api.f).getChatMember(-1, 5).catch(e => e);
  expect(String(e2.message)).not.toContain(TOKEN);
});

test("getUpdates, getChat and getChatMember send the documented bodies and return result", async () => {
  const { f, calls } = stub((url) => ({ json: { ok: true, result: url.endsWith("getUpdates") ? [{ update_id: 1 }] : { id: 5 } } }));
  const tg = new PeerTelegram(TOKEN, f);
  expect(await tg.getUpdates(10, 30)).toEqual([{ update_id: 1 }]);
  expect(calls[0].body).toMatchObject({ offset: 10, timeout: 30 });
  expect(await tg.getChat(-100)).toEqual({ id: 5 });
  expect(calls[1].body).toEqual({ chat_id: -100 });
  await tg.getChatMember(-100, 9);
  expect(calls[2].body).toEqual({ chat_id: -100, user_id: 9 });
  expect(calls.map(c => c.url.split("/").pop())).toEqual(["getUpdates", "getChat", "getChatMember"]);
});

test("every getUpdates names the update types the poller reads, so a stored filter cannot drop a button tap", async () => {
  const { f, calls } = stub(() => ({ json: { ok: true, result: [] } }));
  await new PeerTelegram(TOKEN, f).getUpdates(1, 0);
  expect(calls[0].body.allowed_updates).toEqual(["message", "edited_message", "channel_post", "edited_channel_post", "callback_query"]);
});

test("the Bot API sendMessage method is named only in telegram.ts", () => {
  const dir = import.meta.dir;
  const offenders = readdirSync(dir)
    .filter(n => n.endsWith(".ts") && !n.endsWith(".test.ts") && n !== "telegram.ts")
    .filter(n => /\/sendMessage\b|["'`]sendMessage["'`]\s*,/.test(readFileSync(join(dir, n), "utf8")));
  expect(offenders).toEqual([]);
});
