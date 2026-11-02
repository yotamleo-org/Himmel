// Imported first by main.tsx, before @ag-ui/client builds its zod schemas. zod probes `new Function("")` when
// it builds an object schema; the throw is caught, but the server CSP (default-src 'self') makes the browser
// log it as a script-src eval violation. `jitless` skips the probe and keeps the CSP unchanged.
// ponytail: zod is imported undeclared (only an override in package.json, resolved transitively through @ag-ui/client), so it breaks if @ag-ui/client stops installing one shared zod; upgrade path: declare zod as a direct dependency and bump bun.lock.
import { config } from "zod";

config({ jitless: true });
