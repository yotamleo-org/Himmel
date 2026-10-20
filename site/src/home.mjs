// The Home page: the hero frame (F2) of docs-mockup-v4-agreed.html, copy verbatim,
// with ruling 7's call to action. Loaded by docs-loader.mjs as the `index` entry.
export const homeData = {
  title: 'himmel docs',
  template: 'splash',
  hero: {
    title: 'Let Claude Code work on its own, without letting it wreck your repo.',
    tagline:
      'himmel adds hooks and git gates to Claude Code that refuse risky actions before they run, so the rules hold even when nobody is watching. For developers on Linux or macOS who use git.',
    actions: [
      { text: 'Try it on a throwaway project', link: 'getting-started/', variant: 'primary' },
      { text: 'See the whole trail', link: 'adoption-trail.html', variant: 'minimal' },
    ],
  },
};

export const homeBody = `## What it does

- **Refuses destructive actions.** Edits and commits on your main branch are refused until you make a worktree, and so is a direct push to main. Add the himmel-guard plugin and \`rm -rf\`, hard resets and force pushes are refused before they run.<br>*Level 1 · starter install, plus one plugin*
- **Keeps secrets out of reach.** Claude is refused when it tries to read \`.env\`, key files and other secrets, so it cannot copy a key into its context by opening the file.<br>*Level 1 · starter install*
- **Work survives a closed session.** \`/handover\` writes a note on what was done and what is next, and a fresh session picks up from it.<br>*Level 6 · starter install*
`;
