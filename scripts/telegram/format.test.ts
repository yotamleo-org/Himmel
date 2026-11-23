import { expect, test } from "bun:test";
import { toTelegramHtml } from "./format";

test("markdown marks render as entities: bold, inline code, bullet lists", () => {
  expect(toTelegramHtml("Needs you: **approve** the sign-in\n\n- first `a b`\n- second\n1. one\n2. two"))
    .toBe("Needs you: <b>approve</b> the sign-in\n\n• first <code>a b</code>\n• second\n1. one\n2. two");
});

test("a multi-line message with a plain first line gets a bold lead", () => {
  expect(toTelegramHtml("Workers stopped\n\n- one\n- two")).toBe("<b>Workers stopped</b>\n\n• one\n• two");
});

test("< & > are escaped everywhere, including inside code", () => {
  expect(toTelegramHtml("Use a < b & c > d, then run `x<y>&z`")).toBe("Use a &lt; b &amp; c &gt; d, then run <code>x&lt;y&gt;&amp;z</code>");
});

test("a fenced block becomes pre, escaped, byte-exact inside", () => {
  expect(toTelegramHtml("Run:\n\n```\nls *_a <b>\n```\ndone")).toBe("<b>Run:</b>\n\n<pre>ls *_a &lt;b&gt;</pre>\ndone");
});

test("a one-line fenced command keeps its text, as one pre block", () => {
  expect(toTelegramHtml("```go AB_C*D```")).toBe("<pre>go AB_C*D</pre>");
  expect(toTelegramHtml("Run this:\n\n```go AB_C*D```\n\nthen wait")).toBe("<b>Run this:</b>\n\n<pre>go AB_C*D</pre>\n\nthen wait");
});

test("a lone language word after the fence is a label, not part of the code", () => {
  expect(toTelegramHtml("Run:\n\n```bash\nls -la\n```")).toBe("<b>Run:</b>\n\n<pre>ls -la</pre>");
});

test("language labels such as c# and f# are labels too", () => {
  expect(toTelegramHtml("Run:\n\n```c#\nvar x = 1;\n```")).toBe("<b>Run:</b>\n\n<pre>var x = 1;</pre>");
  expect(toTelegramHtml("Run:\n\n```f#\nlet x = 1\n```")).toBe("<b>Run:</b>\n\n<pre>let x = 1</pre>");
});

test("the rest of a fence opening line is kept, byte-exact", () => {
  expect(toTelegramHtml("Run:\n\n```ls *_a <b>\nmore\n```")).toBe("<b>Run:</b>\n\n<pre>ls *_a &lt;b&gt;\nmore</pre>");
});

test("a code or command alone in a message is wrapped in code and never converted", () => {
  expect(toTelegramHtml("go AB_C*D")).toBe("<code>go AB_C*D</code>");
  expect(toTelegramHtml("6631-AA13")).toBe("<code>6631-AA13</code>");
  expect(toTelegramHtml("echo `date` *x* _y_ | wc")).toBe("<code>echo `date` *x* _y_ | wc</code>");
  expect(toTelegramHtml("tail -f a<b>&c")).toBe("<code>tail -f a&lt;b&gt;&amp;c</code>");
});

test("a long command alone keeps its backticks, byte-exact", () => {
  expect(toTelegramHtml("echo `date` a b c d e f g h")).toBe("<code>echo `date` a b c d e f g h</code>");
});

test("a bold span that contains inline code renders both", () => {
  expect(toTelegramHtml("Please **run `cmd` now** today")).toBe("Please <b>run <code>cmd</code> now</b> today");
});

test("bold marks inside a code span stay literal", () => {
  expect(toTelegramHtml("Run `**x**` now")).toBe("Run <code>**x**</code> now");
});

test("a lone * or _ inside prose is left as typed", () => {
  expect(toTelegramHtml("see go AB_C*D for the code, then wait")).toBe("see go AB_C*D for the code, then wait");
});

test("a short capitalised line with a bold mark is prose, not code", () => {
  expect(toTelegramHtml("Done: **PR 12** merged")).toBe("Done: <b>PR 12</b> merged");
});

test("a plain short sentence alone is not turned into code", () => {
  expect(toTelegramHtml("Done.")).toBe("Done.");
  expect(toTelegramHtml("Nothing lost; restarting them.")).toBe("Nothing lost; restarting them.");
});
