import { test, expect } from "bun:test";
import { railMarkup } from "../public/nav.js";

// The AG-UI app draws the console's rail (railMarkup), so the entries must not depend on which document draws it.
const TOKEN = "a".repeat(64);
const ids = (html: string) => [...html.matchAll(/data-page="([^"]+)"/g)].map((m) => m[1]);

test("railMarkup from the AG-UI page lists the same entries as the console, and reaches the console's pages", () => {
  const consoleRail = railMarkup({ here: "console", token: TOKEN, current: "fleet", dots: {}, waiting: 0 });
  const aguiRail = railMarkup({ here: "agui", token: TOKEN, current: "fleet", dots: {}, waiting: 0 });
  expect(ids(aguiRail)).toEqual(ids(consoleRail));
  expect(ids(aguiRail).length).toBeGreaterThan(0);
  expect(aguiRail).toContain(`href="/#t=${TOKEN}&page=config"`); // a link to a console page leaves the /agui/ document
  expect(railMarkup({ token: TOKEN, current: "fleet", dots: {}, waiting: 0 })).toBe(consoleRail); // no `here`: the console
});
