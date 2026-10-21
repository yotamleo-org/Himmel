// The Workflow page: the development graph, drawn by the docs page's own dev-graph.js from its own graph.json.
// The server hands both out read-only under /dev-graph/. The CSP is default-src 'self': external files only,
// no inline script or style, so the stylesheet is index.html's <link> and the graph sets its styles through the CSSOM.
let loaded = null; // module + data, fetched once per page load; a failure is dropped so the next visit retries
function load() {
  if (!loaded) {
    loaded = Promise.all([
      import("/dev-graph/dev-graph.js"),
      fetch("/dev-graph/graph.json").then((r) => { if (!r.ok) throw new Error(`graph.json: HTTP ${r.status}`); return r.json(); }),
    ]).catch((e) => { loaded = null; throw e; });
  }
  return loaded;
}

export function renderWorkflow() {
  return `<h2>Workflow</h2><p class="sub">How a change travels from a console's dispatch to a merged pull request: the lanes, the gates, and the refusals between them.</p><div id="workflow-graph" aria-label="Development graph"></div>`;
}

// Draws the graph into #workflow-graph once renderWorkflow's markup is in the page; returns the function that undoes it,
// which the caller runs before the next paint replaces that markup (the graph listens on window).
export function mountWorkflow() {
  const el = document.getElementById("workflow-graph");
  let graph = null, gone = false;
  load()
    .then(([mod, data]) => { if (!gone) graph = mod.mount(el, data); })
    .catch((e) => {
      if (gone) return;
      el.textContent = `The development graph did not load: ${e.message}`;
      el.setAttribute("role", "alert");
    });
  return () => { gone = true; if (graph) graph.destroy(); };
}
