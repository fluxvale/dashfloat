import fs from "node:fs";
import path from "node:path";
import { marked, type Tokens } from "marked";

// Docs are read from the repo itself (README.md + docs/decisions/*.md) at
// build time — this directory is website/, so the repo root is one level up.
// `astro build` always runs with website/ as the working directory.
const repoRoot = path.resolve(process.cwd(), "..");
const decisionsDir = path.join(repoRoot, "docs", "decisions");

const GITHUB_BLOB = "https://github.com/fluxvale/dashfloat/blob/main/";

export interface AdrMeta {
  slug: string;
  number: string;
  title: string;
  status: string;
}

const slugify = (text: string): string =>
  text
    .toLowerCase()
    .replace(/[^\w\- ]/g, "")
    .trim()
    .replace(/\s+/g, "-");

// GitHub-style heading ids so in-page anchors (#amendment-...) keep working.
marked.use({
  renderer: {
    heading(token: Tokens.Heading) {
      const text = this.parser.parseInline(token.tokens);
      return `<h${token.depth} id="${slugify(token.text)}">${text}</h${token.depth}>`;
    },
  },
});

// Repo-relative .md links become site links; everything else relative goes
// to the file on GitHub (AGENTS.md, LICENSE, ...).
const ADR_HREF = /^(?:.*\/)?(\d{4}-[^/]+)\.md$/;

function rewriteHref(href: string): string {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("#")) return href;
  const adr = href.match(ADR_HREF);
  if (adr) return `/docs/decisions/${adr[1]}`;
  if (/^(?:\.*\/)*README\.md$/.test(href)) return "/docs/readme";
  return GITHUB_BLOB + href.replace(/^\.\//, "");
}

function rewriteLinks(tokens: Tokens.Generic[] | undefined): void {
  for (const token of tokens ?? []) {
    if (token.type === "link") token.href = rewriteHref(token.href);
    rewriteLinks(token.tokens);
    rewriteLinks(token.items);
    if (Array.isArray(token.rows)) {
      for (const row of token.rows) rewriteLinks(row as unknown as Tokens.Generic[]);
    }
  }
}

export function renderMarkdown(md: string): string {
  const tokens = marked.lexer(md);
  rewriteLinks(tokens);
  return marked.parser(tokens);
}

export function listAdrs(): AdrMeta[] {
  if (!fs.existsSync(decisionsDir)) {
    throw new Error(`docs/decisions not found at ${decisionsDir} — build must run from website/`);
  }
  return fs
    .readdirSync(decisionsDir)
    .filter((f) => /^\d{4}-.*\.md$/.test(f))
    .sort()
    .map((file) => {
      const md = fs.readFileSync(path.join(decisionsDir, file), "utf8");
      const heading = md.match(/^# (\d{4}) — (.+)$/m);
      const status = md.match(/^-\s+\*\*Status:\*\*\s+(.+)$/m);
      return {
        slug: file.replace(/\.md$/, ""),
        number: heading?.[1] ?? file.slice(0, 4),
        title: heading?.[2] ?? file,
        status: status?.[1] ?? "Accepted",
      };
    });
}

export function readAdr(slug: string): string | null {
  if (!/^\d{4}-[a-z0-9-]+$/.test(slug)) return null;
  const file = path.join(decisionsDir, `${slug}.md`);
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
}

export function readReadme(): string {
  return fs.readFileSync(path.join(repoRoot, "README.md"), "utf8");
}
