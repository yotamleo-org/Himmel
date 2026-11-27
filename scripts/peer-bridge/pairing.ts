import { utcDay } from "./ids";

export const PAIR_OFFER_TTL_MS = 30 * 60_000;
export const MAX_OFFERS_PER_DAY = 5;

export type CardOffer = { kind: "card-offer"; peer: string; offer: string; station: string; key: string; chat_id: number; message_id: number; ts: number; exp: number };
export type OfferState = "APPROVED" | "REJECTED" | "EXPIRED" | "REFUSED";
export type OfferResult = { kind: "offer-result"; offer: string; state: OfferState; rule?: string; by?: string; ts: number };
export type PairRec = CardOffer | OfferResult;

export const offersOf = (recs: PairRec[]): CardOffer[] => recs.filter((r): r is CardOffer => r.kind === "card-offer");
export const resultOf = (recs: PairRec[], offer: string): OfferResult | undefined => recs.find((r): r is OfferResult => r.kind === "offer-result" && r.offer === offer);

export function offerState(recs: PairRec[], offer: CardOffer, now: number): OfferState | "OPEN" {
  return resultOf(recs, offer.offer)?.state ?? (now > offer.exp ? "EXPIRED" : "OPEN");
}

export const offeredToday = (offer: CardOffer, now: number): boolean => utcDay(offer.ts * 1000) === utcDay(now);

export const offersToday = (recs: PairRec[], peer: string, now: number): number => offersOf(recs).filter(o => o.peer === peer && offeredToday(o, now)).length;
