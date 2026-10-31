# DashFloat website

The static site served at [dashfloat.com](https://dashfloat.com) — landing page
plus docs — built with [Astro](https://astro.build) (zero client-side JS) and
deployed to GitHub Pages from Actions on push to `main`.

Docs pages are **not** copied in here: the build reads `../README.md` and every
ADR in `../docs/decisions/` straight from the repo (`src/lib/docs.ts`), so there
is a single source of truth. Repo-relative markdown links are rewritten to site
pages; other relative links point back at the file on GitHub. ADR filenames
must match the one shared, anchored pattern in `src/lib/adr.mjs`
(`NNNN-lowercase-kebab.md` — the stem is the URL path segment) everywhere:
the listing filter, the page reader, and the post-build guard all import it,
so a misnamed, mis-cased, or nested decision file fails the build instead of
building an empty page or being silently invisible. Each ADR must carry the
house `# NNNN — title` heading. Titles and statuses are reduced to plain
inline text — raw markdown never reaches the docs index.

```sh
npm ci        # exact installs from package-lock.json
npm run dev   # local dev server
npm test      # build-guard unit tests (filename pattern, leak scan)
npm run build # static output in dist/, then scripts/verify-build.mjs asserts
              # on it — every check fails the build with its reason: CNAME,
              # CSS shipped + referenced, decision entries matching the
              # shared pattern, README/ADR page coverage with rendered
              # content, no markdown leakage in the docs index's ADR table
```

Set `ASTRO_TELEMETRY_DISABLED=1` locally (CI does) if you want builds with
no telemetry call.

Dependencies are pinned to exact versions in `package.json` and
`package-lock.json`; dependabot opens the bumps.
