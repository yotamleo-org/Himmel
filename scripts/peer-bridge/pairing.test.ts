import { expect, test } from "bun:test";
import * as P from "./pairing";

const NOW = Date.UTC(2026, 10, 27, 12);
const offer = (over: Record<string, unknown> = {}) => ({ kind: "card-offer", peer: "example", offer: "0a1b2c3d", station: "example", key: "k", chat_id: -100, message_id: 7, ts: NOW / 1000, exp: NOW + P.PAIR_OFFER_TTL_MS, ...over }) as any;
const result = (state: string, over: Record<string, unknown> = {}) => ({ kind: "offer-result", offer: "0a1b2c3d", state, ts: NOW / 1000, ...over }) as any;

test("an offer is open until its expiry, and expired after it even before any result record", () => {
  const o = offer();
  expect(P.offerState([o], o, NOW)).toBe("OPEN");
  expect(P.offerState([o], o, o.exp)).toBe("OPEN");
  expect(P.offerState([o], o, o.exp + 1)).toBe("EXPIRED");
});

test("the result record decides the state, also past the expiry, and the first one wins", () => {
  const o = offer();
  expect(P.offerState([o, result("APPROVED")], o, o.exp + 1)).toBe("APPROVED");
  expect(P.offerState([o, result("REJECTED"), result("APPROVED")], o, NOW)).toBe("REJECTED");
  expect(P.offerState([o, result("REFUSED", { offer: "ffffffff" })], o, NOW)).toBe("OPEN");
});

test("offers are counted per peer and UTC day", () => {
  const recs = [offer(), offer({ offer: "b", ts: NOW / 1000 - 86_400 }), offer({ offer: "c", peer: "other" }), result("EXPIRED")];
  expect(P.offersToday(recs, "example", NOW)).toBe(1);
  expect([P.PAIR_OFFER_TTL_MS, P.MAX_OFFERS_PER_DAY]).toEqual([1_800_000, 5]);
});
