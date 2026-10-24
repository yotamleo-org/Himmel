// The Home page: the hero frame (F2) of docs-mockup-v5.html, copy verbatim,
// with Quickstart and How a change ships as its calls to action. Loaded by docs-loader.mjs as the `index` entry.
export const homeData = {
  title: 'himmel docs',
  template: 'splash',
  hero: {
    title: 'Ship more with Claude Code, and keep every change reviewable.',
    tagline:
      "himmel puts Claude Code's work on a delivery graph. Each change is built in its own worktree, checked three ways at once, reviewed (by a second model too, once you add one) and merged through one gate. The guardrails apply to every session, including the ones you are not watching. For developers on Linux or macOS who use git.",
    actions: [
      { text: 'Quickstart', link: 'getting-started/', variant: 'primary' },
      { text: 'How a change ships', link: 'adoption-trail.html', variant: 'minimal' },
    ],
  },
};

export const homeBody = `## What it does

- **One road for every change.** Each change gets its own worktree, then passes the tests, a review and one merge gate. No step can be skipped. When a check fails, the change goes back with the reason, so main only gets work that passed.<br>*[How a change ships](../../docs/adoption-trail.html)*
- **Guardrails that hold.** Edits and commits on main, pushes to main, reads of secret files, \`rm -rf\`, hard resets and force pushes are refused before they run.<br>*Level 1 · in your project*
- **Cost you can see.** Heavy work checks your remaining Claude usage first, and the fleet records the cost of what it merges.<br>*Level 5*
`;
