// Build-time guard unit tests (issue #36): the ADR filename pattern and
// the markdown leak scan. Run from website/ via `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import { ADR_FILE } from "../src/lib/adr.mjs";
import { adrNameOffenses, markdownLeak } from "../scripts/verify-build.mjs";
import { listAdrs, readAdr } from "../src/lib/docs.ts";

test("ADR_FILE accepts only NNNN-lowercase-kebab.md, anchored", () => {
  const good = [
    "0001-founding-stack-and-architecture.md",
    "0009-config-v3-persona-profiles.md",
    "0031-a.md",
  ];
  for (const name of good) assert.ok(ADR_FILE.test(name), `should accept ${name}`);

  const bad = [
    "0009-ADR-config-v3.md", // uppercase — the issue #36 repro
    "009-too-short.md", // three digits
    "0009-config_v3.md", // underscore is not URL-safe
    "0009-config v3.md", // a space breaks the slug-as-URL
    "0009-config.v3.md", // dot inside the stem
    "0009-a.md.md", // double extension
    "0009-.md", // empty stem
    "x0009-a.md", // unanchored prefix
    "0009-a.md\n", // trailing newline
    "0009-café.md", // non-ASCII
  ];
  for (const name of bad) assert.ok(!ADR_FILE.test(name), `should reject ${JSON.stringify(name)}`);
});

test("adrNameOffenses flags misnamed decision files, not the index or non-markdown", () => {
  assert.deepEqual(
    adrNameOffenses(["0001-ok.md", "README.md", "0099-ADR-Bogus-Name.md", "notes.txt"]),
    ["0099-ADR-Bogus-Name.md"],
  );
});

test("markdownLeak catches backtick spans and singles, bold, and link tails", () => {
  const leaks = [
    "<td>core `mix release` tarballs</td>", // the live #36 leak (ADR 0010's title)
    "<td>`single backtick</td>",
    "<td>**bold**</td>",
    "<td>see [x](y)</td>",
  ];
  for (const html of leaks) assert.ok(markdownLeak(html), `should catch ${html}`);
  assert.equal(
    markdownLeak('<td>plain 0009</td><a href="/docs/decisions/0009-config-v3">x</a>'),
    null,
  );
});

test("listAdrs and readAdr agree — a mismatched name fails loudly, not with an empty page", () => {
  // cwd is website/, so docs.ts reads the real ../docs/decisions.
  for (const { slug } of listAdrs()) {
    assert.doesNotThrow(() => readAdr(slug), slug);
  }
  assert.throws(() => readAdr("0099-ADR-Bogus-Name"), /does not match .* rename the decision file/);
});

test("docs index text is plain — titles and statuses carry no raw markdown", () => {
  for (const adr of listAdrs()) {
    assert.ok(!/[`*]|\]\(/.test(adr.title), `title leaks: ${adr.title}`);
    assert.ok(!/[`*]|\]\(/.test(adr.status), `status leaks: ${adr.status}`);
  }
});
