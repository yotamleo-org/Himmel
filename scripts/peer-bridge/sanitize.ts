const C0_C1 = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g;
// Bidi controls and zero-width characters.
const INVISIBLE = /[؜᠎​-‏‪-‮⁠-⁤⁦-⁩﻿]/g;
export const C0_C1_TEST = new RegExp(C0_C1.source);
export const INVISIBLE_TEST = new RegExp(INVISIBLE.source);

export function sanitize(text: string, max: number): string {
  let s = text.replace(C0_C1, "").replace(INVISIBLE, "");
  s = s.replace(/<{3,}|>{3,}/g, m => m.split("").join(" "));
  s = s.replace(/<([/!?A-Za-z][^<>\n]*)>/g, "‹$1›").replace(/<\//g, "‹/");
  if (s.length > max) {
    s = s.slice(0, max);
    const last = s.charCodeAt(s.length - 1);
    if (last >= 0xd800 && last <= 0xdbff) s = s.slice(0, -1);
  }
  return s;
}
