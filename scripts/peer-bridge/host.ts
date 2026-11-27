const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function privateIPv4(a: number, b: number): boolean {
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
}

export function badHost(text: string, host: string): boolean {
  for (const m of text.matchAll(/(?<![0-9.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9])/g)) {
    const o = [m[1], m[2], m[3], m[4]].map(Number);
    if (o.every(n => n <= 255) && privateIPv4(o[0], o[1])) return true;
  }
  if (/(?<![A-Za-z0-9-])localhost(?![A-Za-z0-9-])/i.test(text)) return true;
  if (/(?<![0-9A-Fa-f:])::1(?![0-9A-Fa-f:])/.test(text) || /(?<![0-9A-Fa-f])(?:fe80|f[cd][0-9a-f]{2}):/i.test(text)) return true;
  if (/(?<![A-Za-z0-9-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:local|lan|internal|home\.arpa)(?![A-Za-z0-9-])/i.test(text)) return true;
  for (const name of new Set([host, host.split(".")[0]])) {
    if (name.length >= 3 && new RegExp(`(?<![A-Za-z0-9-])${esc(name)}(?![A-Za-z0-9-])`, "i").test(text)) return true;
  }
  return false;
}
