// @ts-check
import { defineConfig } from "astro/config";

// Static output, zero client JS. Content (README + ADRs) is read from the
// repo at build time by src/lib/docs.ts — no content is copied in here.
// Telemetry is off in CI via ASTRO_TELEMETRY_DISABLED; Astro has no config
// key for it. CSS is emitted as a real file (never inlined) so the post-build
// checks can assert it ships and is referenced.
export default defineConfig({
  site: "https://dashfloat.com",
  build: { inlineStylesheets: "never" },
});
