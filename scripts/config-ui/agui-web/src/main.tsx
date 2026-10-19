import { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { FleetPage, useFleet } from "./Fleet";
import { Shell } from "./Shell";
import { consoleFromHash, fleetToken, sourceFromLocation } from "./stream";

// a token with no run is the fleet landing; a fleet row changes the fragment to its run, so the
// page re-routes on hashchange (keyed on the hash so a new run gets a fresh stream). Both sit in
// the config console's rail.
function Root() {
  const [hash, setHash] = useState(location.hash);
  useEffect(() => {
    const on = () => setHash(location.hash);
    addEventListener("hashchange", on);
    return () => removeEventListener("hashchange", on);
  }, []);
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const fleet = useFleet(p.get("t"));
  const token = fleetToken(hash);
  // the census re-renders this root every poll; the source keeps its identity until the run or token changes
  const run = p.get("run");
  const source = useMemo(() => sourceFromLocation(hash), [run, p.get("t")]);
  return (
    <Shell token={p.get("t")} run={p.get("run")} fleet={fleet} console={consoleFromHash(hash)}>
      {token ? <FleetPage token={token} state={fleet} console={consoleFromHash(hash)} /> : <App key={hash} source={source} />}
    </Shell>
  );
}

createRoot(document.getElementById("root")!).render(<Root />);
