// Post-build assertions — the build is not green until the output is sane.
// Runs as part of `npm run build`, so CI and deploys cannot pass on a broken
// dist/. Guards the classes caught in the PR #35 hostile review:
//   1. the custom domain file,
//   2. CSS actually shipping and being referenced (the unstyled-ship P1),
//   3. every repo doc (README + each ADR) having a built page,
//   4. no raw markdown leaking into the docs index (status cells).
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const dist = resolve(process.cwd(), "dist");
const repoRoot = resolve(process.cwd(), "..");

const fail = (message) => {
  console.error(`verify-build: FAIL ${message}`);
  process.exit(1);
};
const ok = (message) => console.log(`verify-build: ok ${message}`);

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

// 3. Every repo doc has a built page — a new ADR or README edit can never
// land silently unbuilt (the build reads them from outside website/).
const decisionsDir = join(repoRoot, "docs", "decisions");
const adrSlugs = readdirSync(decisionsDir)
  .filter((f) => /^\d{4}-.*\.md$/.test(f))
  .map((f) => f.replace(/\.md$/, ""));
const missing = adrSlugs.filter(
  (slug) => !existsSync(join(dist, "docs", "decisions", slug, "index.html")),
);
if (missing.length > 0) fail(`ADRs without a built page: ${missing.join(", ")}`);
if (!existsSync(join(dist, "docs", "readme", "index.html"))) fail("no built README page");
ok(`docs pages: README + ${adrSlugs.length} ADRs`);

// 4. No markdown syntax leaks into the docs index (status cells).
const docsIndex = readFileSync(join(dist, "docs", "index.html"), "utf8");
if (/\*\*|\]\(/.test(docsIndex)) fail("raw markdown leaked into /docs (check status cells)");
ok("no markdown leakage on /docs");

ok("all output assertions passed");
