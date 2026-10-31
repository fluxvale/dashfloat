// Post-build assertions — the build is not green until the output is sane.
// Runs as part of `npm run build`, so CI and deploys cannot pass on a broken
// dist/. Guards the classes caught in the PR #35 hostile review plus the
// issue #36 follow-ups:
//   1. the custom domain file,
//   2. CSS actually shipping and being referenced (the unstyled-ship P1),
//   3. ADR filenames conforming to the one shared pattern (src/lib/adr.mjs)
//      — a misnamed decision file used to build an empty page while this
//      guard watched,
//   4. every repo doc (README + each ADR) having a built, NON-EMPTY page,
//   5. no raw markdown (emphasis, strong, strike, link syntax, code spans)
//      leaking into the docs index's ADR table.
// Every check fails the build with its reason — a guard that warns is a
// guard that isn't. The guard functions are exported for node --test.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ADR_FILE } from "../src/lib/adr.mjs";

// Raw markdown that must never reach built HTML: code spans, emphasis,
// strong, strike, or link tails (issue #36: backticks were missing from
// this scan, and ADR 0010's `mix release` title leaked for real). Titles
// and statuses are stripped to plain inline text before rendering, so any
// hit is leakage. Mirrors plainInline in src/lib/docs.ts.
const MARKDOWN_LEAK = /`|\*|__|~~|\]\(/;

// Every entry in docs/decisions except the index README must be a
// well-named ADR — a misnamed, mis-cased, or nested file fails the build
// instead of being silently invisible on the site.
export function adrNameOffenses(files) {
  return files.filter((f) => f !== "README.md" && !ADR_FILE.test(f));
}

// The raw-markdown fragment (with context) in built HTML, for the reason.
export function markdownLeak(html) {
  const at = html.search(MARKDOWN_LEAK);
  return at === -1 ? null : html.slice(Math.max(0, at - 20), at + 20);
}

const fail = (message) => {
  console.error(`verify-build: FAIL ${message}`);
  process.exit(1);
};
const ok = (message) => console.log(`verify-build: ok ${message}`);

function main() {
  const dist = resolve(process.cwd(), "dist");
  const repoRoot = resolve(process.cwd(), "..");
  if (!existsSync(dist)) fail("dist/ does not exist");

  // 1. CNAME — Pages reads it to bind the custom domain.
  const cname = readFileSync(join(dist, "CNAME"), "utf8").trim();
  if (cname !== "dashfloat.com") fail(`CNAME is "${cname}", expected "dashfloat.com"`);
  ok("CNAME = dashfloat.com");

  // 2. CSS ships as a real file and index.html links it.
  const walk = (dir) =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const full = join(dir, entry.name);
      return entry.isDirectory() ? walk(full) : [full];
    });
  const cssFiles = walk(dist).filter((f) => f.endsWith(".css"));
  if (cssFiles.length === 0) fail("no .css file in dist");
  const indexHtml = readFileSync(join(dist, "index.html"), "utf8");
  const cssHref = indexHtml.match(/href="([^"]+\.css)"/)?.[1];
  if (!cssHref) fail("index.html does not reference a stylesheet");
  const cssPath = join(dist, cssHref.replace(/^\//, ""));
  if (!existsSync(cssPath) || readFileSync(cssPath, "utf8").length === 0) {
    fail(`index.html references ${cssHref} but it is missing or empty in dist`);
  }
  ok(`CSS ships and is referenced (${cssHref}, ${cssFiles.length} file(s))`);

  // 3. ADR filenames conform to the one pattern the site itself uses.
  const decisionsDir = join(repoRoot, "docs", "decisions");
  const files = readdirSync(decisionsDir);
  const offenders = adrNameOffenses(files);
  if (offenders.length > 0) {
    fail(`misnamed ADR file(s) in docs/decisions — expected ${ADR_FILE}: ${offenders.join(", ")}`);
  }
  const adrSlugs = files.filter((f) => ADR_FILE.test(f)).map((f) => f.replace(/\.md$/, ""));

  // 4. Every repo doc has a built, non-empty page — a new ADR or README
  //    edit can never land silently unbuilt, and the empty page of issue
  //    #36 (index row with no content) is caught by the missing rendered
  //    H1.
  const missing = adrSlugs.filter(
    (slug) => !existsSync(join(dist, "docs", "decisions", slug, "index.html")),
  );
  if (missing.length > 0) fail(`ADRs without a built page: ${missing.join(", ")}`);
  const empty = adrSlugs.filter(
    (slug) => !readFileSync(join(dist, "docs", "decisions", slug, "index.html"), "utf8").includes("<h1"),
  );
  if (empty.length > 0) fail(`ADR pages with no rendered heading (empty page): ${empty.join(", ")}`);
  const readmePage = join(dist, "docs", "readme", "index.html");
  if (!existsSync(readmePage)) fail("no built README page");
  if (!readFileSync(readmePage, "utf8").includes("<h1")) fail("README page has no rendered heading");
  ok(`docs pages: README + ${adrSlugs.length} ADRs`);

  // 5. No markdown syntax leaks into the docs index — scan the ADR table's
  //    rows (title/status cells), where repo text lands raw, not the page
  //    chrome around it.
  const docsIndex = readFileSync(join(dist, "docs", "index.html"), "utf8");
  const tbody = docsIndex.match(/<tbody>[\s\S]*<\/tbody>/);
  if (!tbody) fail("docs index has no ADR table (tbody) to scan");
  const leak = markdownLeak(tbody[0]);
  if (leak) fail(`raw markdown leaked into /docs: …${leak}… (check title/status cells)`);
  ok("no markdown leakage on /docs");

  ok("all output assertions passed");
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) main();
