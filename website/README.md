# DashFloat website

The static site served at [dashfloat.com](https://dashfloat.com) — landing page
plus docs — built with [Astro](https://astro.build) (zero client-side JS) and
deployed to GitHub Pages from Actions on push to `main`.

Docs pages are **not** copied in here: the build reads `../README.md` and every
ADR in `../docs/decisions/` straight from the repo (`src/lib/docs.ts`), so there
is a single source of truth. Repo-relative markdown links are rewritten to site
pages; other relative links point back at the file on GitHub.

```sh
npm ci        # exact installs from package-lock.json
npm run dev   # local dev server
npm run build # static output in dist/ (includes public/CNAME)
```

Dependencies are pinned to exact versions in `package.json` and
`package-lock.json`; dependabot opens the bumps.
