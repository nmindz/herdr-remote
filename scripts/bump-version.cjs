#!/usr/bin/env node
// Bump the SINGLE SOURCE OF TRUTH for this repo's version — the root `VERSION` file — plus the two
// herdr plugin manifests, which carry a copy that herdr records at install time.
//
// Everything else derives at build time and needs no edit here:
//   Makefile         VERSION ?= $(shell cat VERSION)
//   build.sh/dmg.sh  fall back to reading ../VERSION
//   Info.plist       written by build.sh from $VERSION
//   Updater.swift    reads CFBundleShortVersionString at runtime
//
// herdr itself does NOT act on the manifest `version` — it pins plugins by commit SHA
// (`source.resolved_commit` in ~/.config/herdr/plugins.json) and only records `version` for
// display. `min_herdr_version` is the field with real gating semantics, so it is left alone.
//
// Usage: node scripts/bump-version.cjs <version>
// Called by semantic-release (prepareCmd). Lives in a file — NOT an inline `node -e` — so shell
// quoting can never mangle it.

const fs = require("fs");
const path = require("path");

const version = process.argv[2];
if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.\-]+)?(\+[0-9A-Za-z.\-]+)?$/.test(version || "")) {
  console.error(`bump-version: invalid or missing version: ${version}`);
  process.exit(1);
}

const root = path.resolve(__dirname, "..");
const rel = (p) => path.relative(root, p) || p;

// ── The canonical file ────────────────────────────────────────────────────────
const versionFile = path.join(root, "VERSION");
fs.writeFileSync(versionFile, `${version}\n`);
console.log(`Bumped ${rel(versionFile)} to ${version}`);

// ── herdr plugin manifests ────────────────────────────────────────────────────
// Anchored to a line-start `version = "…"`, so `min_herdr_version` is never matched.
const manifests = [
  path.join(root, "herdr-plugin.toml"),
  path.join(root, "relay", "herdr-plugin.toml"),
];

for (const file of manifests) {
  if (!fs.existsSync(file)) {
    console.error(`bump-version: expected manifest missing: ${rel(file)}`);
    process.exit(1);
  }
  const before = fs.readFileSync(file, "utf8");
  const after = before.replace(/^version = ".*"$/m, `version = "${version}"`);
  if (after === before) {
    // Either the line is absent or it already reads `version`. Distinguish, so an idempotent
    // re-run stays quiet but a genuinely unmatched file fails the release.
    if (!new RegExp(`^version = "${version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"$`, "m").test(before)) {
      console.error(`bump-version: no version line matched in ${rel(file)}`);
      process.exit(1);
    }
    console.log(`${rel(file)} already at ${version}`);
    continue;
  }
  fs.writeFileSync(file, after);
  console.log(`Bumped ${rel(file)} to ${version}`);
}
