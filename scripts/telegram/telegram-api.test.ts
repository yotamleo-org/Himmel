import { expect, test, spyOn, mock } from "bun:test";
import { answerCallbackQuery, getUpdates, sendMessage, sendChatAction } from "./telegram-api";

test("sendMessage exposes the accepted message id for console reply threading only on success", async () => {
  const ids: number[] = [];
  const fetchOk = async () => new Response(JSON.stringify({ ok: true, result: { message_id: 777 } }));
  expect(await sendMessage("T", 1, "answer", fetchOk as any, async () => {}, id => { ids.push(id); })).toBe(true);
  expect(ids).toEqual([777]);
  const fetchFail = async () => new Response(JSON.stringify({ ok: false, result: { message_id: 888 } }), { status: 400 });
  expect(await sendMessage("T", 1, "answer", fetchFail as any, async () => {}, id => { ids.push(id); })).toBe(false);
  expect(ids).toEqual([777]);
});

test("threaded reply survives deleted inbound message and retains its receipt", async () => {
  const ids: number[] = [];
  const fakeFetch = async (_url: string, init: any) => {
    const body = JSON.parse(init.body);
    return body.reply_parameters?.allow_sending_without_reply === true
      ? Response.json({ ok: true, result: { message_id: 777 } })
      : Response.json({ ok: false, description: "Bad Request: message to be replied not found" }, { status: 400 });
  };
  expect(await sendMessage("T", 1, "queued", fakeFetch as any, async () => {}, id => { ids.push(id); }, 123)).toBe(true);
  expect(ids).toEqual([777]);
});

test("sendChatAction posts chat_id + action; failure is swallowed (best-effort)", async () => {
  const bodies: any[] = [];
  const fakeFetch = async (_url: string, init: any) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify({ ok: true })); };
  await sendChatAction("T", 42, fakeFetch as any);
  expect(bodies[0]).toEqual({ chat_id: 42, action: "typing" });
  const failFetch = async () => { throw new Error("net down"); };
  await sendChatAction("T", 42, failFetch as any);   // must not throw
});
test("getUpdates passes offset+timeout and returns updates", async () => {
  const calls: string[] = [];
  const fakeFetch = async (url: string) => { calls.push(url);
    return new Response(JSON.stringify({ ok: true, result: [{ update_id: 5 }] })); };
  const r = await getUpdates("TOKEN", 4, 30, fakeFetch as any);
  expect(r[0].update_id).toBe(5);
  expect(calls[0]).toContain("offset=4"); expect(calls[0]).toContain("timeout=30");
});
test("getUpdates returns [] on a malformed ok:true with no result array (no throw)", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: true }));   // result missing
  const r = await getUpdates("TOKEN", 0, 30, fakeFetch as any);
  expect(r).toEqual([]);
});
test("getUpdates THROWS on a non-ok response so the poller's catch can back off instead of hot-looping", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: false, description: "Bad Gateway" }), { status: 502 });
  await expect(getUpdates("TOKEN", 0, 30, fakeFetch as any)).rejects.toThrow(/Bad Gateway/);
});
test("getUpdates non-ok error falls back to the HTTP status when description is absent", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: false }), { status: 502 });
  await expect(getUpdates("TOKEN", 0, 30, fakeFetch as any)).rejects.toThrow(/502/);
});
test("getUpdates aborts a stalled request within its client-side deadline — a transport that never resolves must still REJECT, not hang forever, so the poller's catch/backoff fires", async () => {
  // Models a stuck transport: the fetch promise never resolves on its own, only
  // rejecting when the AbortSignal getUpdates wires up actually fires, exactly
  // what a real fetch implementation does under an AbortSignal (this is the same
  // contract getFile/downloadFile already rely on for FILE_FETCH_TIMEOUT_MS).
  // `timeout=0` and a 20ms abortMarginMs keep the deadline (0*1000+20=20ms) tiny
  // so the test doesn't wait out a real long-poll window.
  const stallForever = (_url: string, init?: { signal?: AbortSignal }) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new Error("The operation was aborted.")));
    });
  const start = Date.now();
  await expect(getUpdates("TOKEN", 0, 0, stallForever as any, 20)).rejects.toThrow();
  expect(Date.now() - start).toBeLessThan(2000);   // rejected via the 20ms deadline, not left hanging
});
test("getUpdates passes an AbortSignal to fetch so a stalled request CAN be aborted (wiring pin)", async () => {
  let sawSignal: AbortSignal | undefined;
  const fakeFetch = async (_url: string, init?: { signal?: AbortSignal }) => {
    sawSignal = init?.signal;
    return new Response(JSON.stringify({ ok: true, result: [] }));
  };
  await getUpdates("TOKEN", 0, 30, fakeFetch as any);
  expect(sawSignal).toBeInstanceOf(AbortSignal);
});
test("sendMessage honors 429 retry_after then succeeds", async () => {
  let n = 0; const sleeps: number[] = [];
  const fakeFetch = async () => { n++;
    if (n === 1) return new Response(JSON.stringify({ ok:false, error_code:429, parameters:{ retry_after:2 }}), {status:429});
    return new Response(JSON.stringify({ ok:true, result:{} })); };
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, (s:number)=>{sleeps.push(s);return Promise.resolve();});
  expect(sleeps).toEqual([2000]);
  expect(ok).toBe(true);        // delivered after the retry
});
test("sendMessage drops on 400 client error without looping or sleeping, and reports not-delivered", async () => {
  let n = 0; const sleeps: number[] = [];
  const fakeFetch = async () => { n++;
    return new Response(JSON.stringify({ ok:false, error_code:400, description:"chat not found" }), {status:400}); };
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, (s:number)=>{sleeps.push(s);return Promise.resolve();});
  expect(n).toBe(1);            // called once, no retry loop
  expect(sleeps).toEqual([]);   // permanent error → no sleep
  expect(ok).toBe(false);       // permanent drop → false (never silently "delivered")
});
test("sendMessage does NOT report delivered on HTTP 200 with ok:false (validates Telegram's ok flag)", async () => {
  let n = 0;
  const fakeFetch = async () => { n++;
    return new Response(JSON.stringify({ ok:false, description:"blocked" }), {status:200}); };  // 2xx but app-level failure
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, () => Promise.resolve());
  expect(ok).toBe(false);       // must not treat a 200/{ok:false} as delivered
  expect(n).toBe(5);            // bounded retry, then gives up (no infinite loop)
});
test("sendMessage logs a redacted transport failure, does not retry, and returns false", async () => {
  const fakeFetch = mock(async () => { throw new Error("net down"); });
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    const ok = await sendMessage("T", 123, "hi", fakeFetch as any);
    expect(ok).toBe(false);
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledWith("[telegram] sendMessage transport failure chat=***23");
  } finally { error.mockRestore(); }
});
test("sendMessage fully redacts one- and two-digit chat ids in logs, including signed ids", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok:false, description:"bad" }), {status:400});
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    await sendMessage("T", 7, "hi", fakeFetch as any);
    await sendMessage("T", 42, "hi", fakeFetch as any);
    await sendMessage("T", -42, "hi", fakeFetch as any);
    expect(error.mock.calls.map(([message]) => String(message))).toEqual([
      "[telegram] sendMessage 400 chat=***: bad",
      "[telegram] sendMessage 400 chat=***: bad",
      "[telegram] sendMessage 400 chat=***: bad",
    ]);
  } finally { error.mockRestore(); }
});
test("sendMessage reports a too-long message as not delivered and logs Telegram's status and reason", async () => {
  const fakeFetch = mock(async () => new Response(JSON.stringify({ ok:false, error_code:400, description:"Bad Request: message is too long" }), {status:400}));
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    const ok = await sendMessage("T", 123, "x".repeat(5000), fakeFetch as any);
    expect(ok).toBe(false);
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledWith("[telegram] sendMessage 400 chat=***23: Bad Request: message is too long");
  } finally { error.mockRestore(); }
});
test("sendMessage sends a text over 4096 characters as ordered parts: reply on the first, markup on the last, a receipt per part", async () => {
  const bodies: any[] = [];
  const f = (async (_u: string, init: any) => { bodies.push(JSON.parse(init.body)); return Response.json({ ok: true, result: { message_id: bodies.length } }); }) as any;
  const ids: number[] = [];
  const markup = { force_reply: true };
  expect(await sendMessage("T", 1, "word ".repeat(1500), f, async () => {}, id => { ids.push(id); }, 55, markup)).toBe(true);
  expect(bodies.length).toBeGreaterThan(1);
  expect(bodies.map(b => b.reply_parameters?.message_id)).toEqual([55, ...bodies.slice(1).map(() => undefined)]);
  expect(bodies.map(b => b.reply_markup)).toEqual([...bodies.slice(0, -1).map(() => undefined), markup]);
  expect(ids).toEqual(bodies.map((_, i) => i + 1));
});
test("sendMessage stops at the first part Telegram does not accept", async () => {
  let calls = 0;
  const f = (async () => { calls++; return calls === 2 ? new Response(JSON.stringify({ ok: false, description: "bad" }), { status: 400 }) : Response.json({ ok: true, result: { message_id: calls } }); }) as any;
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(await sendMessage("T", 1, "word ".repeat(3000), f, async () => {})).toBe(false);
    expect(calls).toBe(2);
  } finally { error.mockRestore(); }
});
// --- getFile + downloadFile ---
import { getFile, downloadFile } from "./telegram-api";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("getFile resolves file_id to file_path", async () => {
  const calls: string[] = [];
  const fakeFetch = async (url: string) => { calls.push(url);
    return new Response(JSON.stringify({ ok: true, result: { file_path: "photos/file_1.jpg" } })); };
  const fp = await getFile("TOKEN", "abc def", fakeFetch as any);
  expect(fp).toBe("photos/file_1.jpg");
  expect(calls[0]).toContain("file_id=abc%20def");   // file_id is URL-encoded
});

test("getFile returns null on not-ok / missing file_path (no throw)", async () => {
  expect(await getFile("T", "x", (async () => new Response(JSON.stringify({ ok: false, description: "bad" }))) as any)).toBeNull();
  expect(await getFile("T", "x", (async () => new Response(JSON.stringify({ ok: true, result: {} }))) as any)).toBeNull();
});

test("downloadFile writes the bytes to dest and returns true", async () => {
  const dest = join(mkdtempSync(join(tmpdir(), "tg-dl-")), "img.jpg");
  const fakeFetch = async (url: string) => {
    expect(url).toBe("https://api.telegram.org/file/botTOKEN/photos/file_1.jpg");
    return new Response(new Uint8Array([1, 2, 3]));
  };
  expect(await downloadFile("TOKEN", "photos/file_1.jpg", dest, fakeFetch as any)).toBe(true);
  expect([...readFileSync(dest)]).toEqual([1, 2, 3]);
});

test("downloadFile returns false on a non-ok response", async () => {
  const dest = join(mkdtempSync(join(tmpdir(), "tg-dl-")), "img.jpg");
  const fakeFetch = async () => new Response("nope", { status: 404 });
  expect(await downloadFile("TOKEN", "p.jpg", dest, fakeFetch as any)).toBe(false);
});

test("sendMessage carries a reply_markup (the ForceReply prompt) and still reports the message id", async () => {
  let body: any;
  const f = async (_u: string, init: any) => { body = JSON.parse(init.body); return new Response(JSON.stringify({ ok: true, result: { message_id: 55 } })); };
  const ids: number[] = [];
  const markup = { force_reply: true, input_field_placeholder: "6-digit code" };
  expect(await sendMessage("T", 1, "Code for abcdefgh:", f as any, async () => {}, id => { ids.push(id); }, undefined, markup)).toBe(true);
  expect(body.reply_markup).toEqual(markup);
  expect(ids).toEqual([55]);
  let plain: any;
  await sendMessage("T", 1, "x", (async (_u: string, init: any) => { plain = JSON.parse(init.body); return new Response(JSON.stringify({ ok: true, result: {} })); }) as any);
  expect("reply_markup" in plain).toBe(false);
});

test("answerCallbackQuery posts the id and text, and never throws", async () => {
  let url = ""; let body: any;
  await answerCallbackQuery("T", "cb9", "Not authorized.", (async (u: string, init: any) => { url = u; body = JSON.parse(init.body); return new Response("{}"); }) as any);
  expect(url).toContain("/answerCallbackQuery");
  expect(body).toEqual({ callback_query_id: "cb9", text: "Not authorized." });
  await answerCallbackQuery("T", "cb9", "x", (async () => { throw new Error("down"); }) as any);
});

import { sendMessageResult, TelegramApiError } from "./telegram-api";
const status = (code: number, j?: object) => (async () => new Response(JSON.stringify(j ?? { ok: false, description: "x" }), { status: code })) as any;
const throwing = (e: unknown) => (async () => { throw e; }) as any;
const coded = (code: string) => Object.assign(new TypeError(code), { code });

test("sendMessageResult returns permanent with code 400 and 403", async () => {
  expect(await sendMessageResult("T", 1, "x", {}, status(400))).toEqual({ ok: false, code: 400, kind: "permanent" });
  expect(await sendMessageResult("T", 1, "x", {}, status(403))).toEqual({ ok: false, code: 403, kind: "permanent" });
});
test("429 and 5xx return transient", async () => {
  expect(await sendMessageResult("T", 1, "x", {}, status(429, { ok: false, parameters: { retry_after: 3 } }))).toEqual({ ok: false, code: 429, kind: "transient" });
  expect(await sendMessageResult("T", 1, "x", {}, status(502))).toEqual({ ok: false, code: 502, kind: "transient" });
  expect(await sendMessageResult("T", 1, "x", {}, status(200, { ok: false }))).toEqual({ ok: false, code: 200, kind: "transient" });
});
test("ECONNREFUSED, ENOTFOUND and EAI_AGAIN return not-sent", async () => {
  for (const c of ["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN"]) {
    expect(await sendMessageResult("T", 1, "x", {}, throwing(coded(c)))).toEqual({ ok: false, code: null, kind: "not-sent" });
    expect(await sendMessageResult("T", 1, "x", {}, throwing(Object.assign(new TypeError("fetch failed"), { cause: { code: c } })))).toEqual({ ok: false, code: null, kind: "not-sent" });
  }
});
test("a reset or abort after the request was written returns maybe-sent", async () => {
  expect(await sendMessageResult("T", 1, "x", {}, throwing(coded("ECONNRESET")))).toEqual({ ok: false, code: null, kind: "maybe-sent" });
  expect(await sendMessageResult("T", 1, "x", {}, throwing(new DOMException("aborted", "AbortError")))).toEqual({ ok: false, code: null, kind: "maybe-sent" });
});
test("a request past timeoutMs returns maybe-sent", async () => {
  const hang = ((_u: string, init: any) => new Promise((_res, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)))) as any;
  const t0 = Date.now();
  expect(await sendMessageResult("T", 1, "x", { timeoutMs: 30 }, hang)).toEqual({ ok: false, code: null, kind: "maybe-sent" });
  expect(Date.now() - t0).toBeLessThan(2000);
});
test("noPreview sends link_preview_options.is_disabled", async () => {
  const bodies: any[] = [];
  const f = (async (_u: string, init: any) => { bodies.push(JSON.parse(init.body)); return Response.json({ ok: true, result: { message_id: 9 } }); }) as any;
  expect(await sendMessageResult("T", 1, "x", { noPreview: true, replyToMessageId: 4, replyMarkup: { inline_keyboard: [] } }, f)).toEqual({ ok: true, messageId: 9 });
  await sendMessageResult("T", 1, "x", {}, f);
  expect(bodies[0].link_preview_options).toEqual({ is_disabled: true });
  expect(bodies[0].reply_parameters).toEqual({ message_id: 4, allow_sending_without_reply: true });
  expect(bodies[0].reply_markup).toEqual({ inline_keyboard: [] });
  expect("link_preview_options" in bodies[1]).toBe(false);
});
test("getUpdates throws TelegramApiError with code 409", async () => {
  const e = await getUpdates("T", 0, 30, status(409, { ok: false, error_code: 409, description: "Conflict" })).catch(x => x);
  expect(e).toBeInstanceOf(TelegramApiError);
  expect(e.code).toBe(409);
  expect(String(e.message)).toMatch(/Conflict/);
});
test("sendMessage still returns a boolean for every case above", async () => {
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    const none = async () => {};
    for (const f of [status(400), status(403), status(502), throwing(coded("ECONNREFUSED")), throwing(coded("ECONNRESET"))]) expect(await sendMessage("T", 1, "x", f, none)).toBe(false);
    expect(await sendMessage("T", 1, "x", (async () => Response.json({ ok: true, result: { message_id: 1 } })) as any, none)).toBe(true);
  } finally { error.mockRestore(); }
});

const capture = (statuses: Array<{ status: number; body: object }>) => {
  const bodies: any[] = [];
  const f = async (_u: string, init: any) => {
    bodies.push(JSON.parse(init.body));
    const r = statuses.shift() ?? { status: 200, body: { ok: true, result: { message_id: 1 } } };
    return Response.json(r.body, { status: r.status });
  };
  return { bodies, f: f as any };
};

test("a flagged send posts Telegram HTML with parse_mode; a command alone stays byte-exact in code", async () => {
  const c = capture([]);
  expect(await sendMessage("T", 1, "go AB_C*D", c.f, async () => {}, undefined, undefined, undefined, true)).toBe(true);
  expect(c.bodies[0].parse_mode).toBe("HTML");
  expect(c.bodies[0].text).toBe("<code>go AB_C*D</code>");
  const d = capture([]);
  await sendMessage("T", 1, "echo `date` *x* _y_ | wc", d.f, async () => {}, undefined, undefined, undefined, true);
  expect(d.bodies[0].text).toBe("<code>echo `date` *x* _y_ | wc</code>");
});

test("an unflagged send is unchanged: no parse_mode, the exact text", async () => {
  const c = capture([]);
  const text = "**not bold** <b>raw</b> & `x` go AB_C*D";
  await sendMessage("T", 1, text, c.f, async () => {});
  expect(c.bodies[0]).toEqual({ chat_id: 1, text });
});

test("a refused entity resends the plain text once, without parse_mode", async () => {
  const c = capture([{ status: 400, body: { ok: false, description: "Bad Request: can't parse entities: Unsupported start tag" } }]);
  expect(await sendMessage("T", 1, "Hello **x**", c.f, async () => {}, undefined, undefined, undefined, true)).toBe(true);
  expect(c.bodies.length).toBe(2);
  expect(c.bodies[0].parse_mode).toBe("HTML");
  expect(c.bodies[1]).toEqual({ chat_id: 1, text: "Hello **x**" });
});

test("a 400 that is not an entity refusal is not resent", async () => {
  const c = capture([{ status: 400, body: { ok: false, description: "Bad Request: chat not found" } }]);
  expect(await sendMessage("T", 1, "Hello **x**", c.f, async () => {}, undefined, undefined, undefined, true)).toBe(false);
  expect(c.bodies.length).toBe(1);
});
