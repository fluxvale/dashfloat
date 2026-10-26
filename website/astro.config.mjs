// @ts-check
import { defineConfig } from "astro/config";

// Static output, zero client JS. Content (README + ADRs) is read from the
// repo at build time by src/lib/docs.ts — no content is copied in here.
export default defineConfig({
  site: "https://dashfloat.com",
});
