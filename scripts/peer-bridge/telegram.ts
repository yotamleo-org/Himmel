// The peer bridge's whole Telegram surface: five Bot API calls. Plain text only,
// link previews always off, no parse_mode. This is the only file that names the
// Bot API's send method.
type F = typeof fetch;

export class RetryAfter extends Error {
  constructor(public seconds: number) { super(`telegram asked to retry after ${seconds}s`); this.name = "RetryAfter"; }
}

export class TelegramError extends Error {
  constructor(message: string, public code: number, public parameters: Record<string, any> = {}) { super(message); this.name = "TelegramError"; }
}

const CALL_TIMEOUT_MS = 15_000;
const POLL_MARGIN_MS = 10_000;
// An omitted list keeps the previous one: https://core.telegram.org/bots/api#getupdates
const ALLOWED_UPDATES = ["message", "edited_message", "channel_post", "edited_channel_post", "callback_query"];

export class PeerTelegram {
  constructor(private token: string, private f: F = fetch) {}

  private scrub(text: string): string {
    const secret = this.token.split(":")[1] ?? this.token;
    return text.split(this.token).join("<token>").split(secret).join("<token>");
  }

  private async call(method: string, body: Record<string, unknown>, timeoutMs = CALL_TIMEOUT_MS): Promise<any> {
    let res: Response;
    try {
      res = await this.f(`https://api.telegram.org/bot${this.token}/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      throw new TelegramError(this.scrub(`${method} failed: ${(e as Error)?.message ?? "network error"}`), 0);
    }
    const j: any = await res.json().catch(() => ({}));
    if (j?.ok === true) return j.result;
    const code = Number(j?.error_code ?? res.status);
    if (code === 429) throw new RetryAfter(Number(j?.parameters?.retry_after) || 1);
    throw new TelegramError(this.scrub(`${method} not ok (${code}): ${j?.description ?? res.status}`), code, j?.parameters ?? {});
  }

  getUpdates(offset: number, timeout: number): Promise<any[]> {
    return this.call("getUpdates", { offset, timeout, allowed_updates: ALLOWED_UPDATES }, timeout * 1000 + POLL_MARGIN_MS).then(r => (Array.isArray(r) ? r : []));
  }

  sendMessage(chatId: number, text: string, replyTo?: number, replyMarkup?: Record<string, unknown>): Promise<{ message_id: number }> {
    const body: Record<string, unknown> = { chat_id: chatId, text, link_preview_options: { is_disabled: true } };
    if (replyTo !== undefined) body.reply_parameters = { message_id: replyTo };
    if (replyMarkup !== undefined) body.reply_markup = replyMarkup;
    return this.call("sendMessage", body);
  }

  answerCallbackQuery(id: string, text: string): Promise<unknown> { return this.call("answerCallbackQuery", { callback_query_id: id, text }); }

  getChat(chatId: number): Promise<any> { return this.call("getChat", { chat_id: chatId }); }
  getChatMember(chatId: number, userId: number): Promise<any> { return this.call("getChatMember", { chat_id: chatId, user_id: userId }); }
}
