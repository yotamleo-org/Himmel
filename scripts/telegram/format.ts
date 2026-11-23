const esc = (s: string): string => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function isCodeAlone(s: string): boolean {
  if (/\n/.test(s) || /[.!?]$/.test(s)) return false;
  if (!/\s/.test(s)) return /\d/.test(s);
  return /^[a-z.\/~$]/.test(s) && !/,\s/.test(s) && !/\*\*[^*]+\*\*/.test(s) && /[*_`$|&;<>=\\]/.test(s);
}

function code(s: string): string {
  return s.split(/(`[^`\n]+`)/).map((seg, i) => i % 2 === 1 ? `<code>${esc(seg.slice(1, -1))}</code>` : esc(seg)).join("");
}

function inline(line: string): string {
  let out = "";
  let last = 0;
  for (const m of line.matchAll(/`[^`\n]+`|\*\*(?:[^*\n`]|`[^`\n]*`)+\*\*/g)) {
    const t = m[0];
    out += esc(line.slice(last, m.index)) + (t[0] === "`" ? `<code>${esc(t.slice(1, -1))}</code>` : `<b>${code(t.slice(2, -2))}</b>`);
    last = m.index + t.length;
  }
  return out + esc(line.slice(last));
}

export function toTelegramHtml(text: string): string {
  const trimmed = text.trim();
  if (isCodeAlone(trimmed)) return `<code>${esc(trimmed)}</code>`;
  const lines = text.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const oneLine = /^```(.+?)```\s*$/.exec(lines[i]);
    if (oneLine) {
      out.push(`<pre>${esc(oneLine[1])}</pre>`);
      continue;
    }
    if (/^```/.test(lines[i])) {
      const rest = lines[i].slice(3);
      let j = i + 1;
      const closeAt = lines.findIndex((l, k) => k > i && /^```\s*$/.test(l));
      const body: string[] = rest && !(closeAt > 0 && /^[A-Za-z0-9_+#.-]+$/.test(rest)) ? [rest] : [];
      while (j < lines.length && !/^```\s*$/.test(lines[j])) body.push(lines[j++]);
      out.push(`<pre>${esc(body.join("\n"))}</pre>`);
      i = j;
      continue;
    }
    const bullet = /^(\s*)[-*] (.*)$/.exec(lines[i]);
    out.push(bullet ? `${bullet[1]}• ${inline(bullet[2])}` : inline(lines[i]));
  }
  const first = lines[0];
  const next = lines[1];
  if (lines.length > 1 && first.trim() && first.length <= 100 && !/\*\*|`|^\s*[-*] /.test(first)
      && (next.trim() === "" || /^\s*([-*]|\d+\.) /.test(next))) out[0] = `<b>${out[0]}</b>`;
  return out.join("\n");
}
