# research-path fixtures

Excerpts of live keyless responses captured 2026-10-16 (HIMMEL-5862), unedited apart from the pre-commit trailing-whitespace and end-of-file normalisation; nothing hand-written.

- `reddit-search.html`: first 3 result units of `https://www.reddit.com/search/?q=claude+code+hooks&sort=top&t=month`, fetched with Scrapling `StealthyFetcher`.
- `reddit-thread.html`: the `<shreddit-post>` open tag and the first 3 comments (through the first `</p>` of each) of `/r/technology/comments/1wn7qdj/`, same fetcher.
- `arctic-shift-ids.json`: `https://arctic-shift.photon-reddit.com/api/posts/ids?ids=<the 7 ids of that search page>`, whole body.
- `arctic-shift-posts.json`: an earlier Arctic Shift posts/search body (r/ClaudeAI), whole body.
