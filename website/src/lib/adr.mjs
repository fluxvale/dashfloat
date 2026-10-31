// The one ADR filename pattern (issue #36): the site's listing filter, the
// page reader, and the post-build guard all import this, so the three can
// never disagree again — a misnamed decision file fails the build instead
// of building an empty page. NNNN-lowercase-kebab.md, anchored: the stem
// doubles as the /docs/decisions/ URL path segment, so it stays URL-safe.
export const ADR_FILE = /^\d{4}-[a-z0-9-]+\.md$/;
