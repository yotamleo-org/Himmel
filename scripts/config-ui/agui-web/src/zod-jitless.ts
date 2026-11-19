// Imported first by main.tsx, before @ag-ui/client builds its zod schemas. zod probes `new Function("")` when
// it builds an object schema; the throw is caught, but the server CSP (default-src 'self') makes the browser
// log it as a script-src eval violation. `jitless` skips the probe and keeps the CSP unchanged.
import { config } from "zod";

config({ jitless: true });
