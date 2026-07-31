#!/usr/bin/env bun
//
// Pull a single version's notes out of a Keep-a-Changelog-style CHANGELOG.md.
//
// Usage (prints the section body on stdout; empty if there is no such section):
//   bun scripts/changelog.ts 1.1
//
// The release workflow uses it to write the GitHub Release's notes.
import { join } from "node:path";
import { die } from "./lib";

/** The version token from a level-2 heading, or null if it isn't one.
 *  Handles `## [1.1] - 2026-07-20`, `## 1.1`, `## v1.1`, etc. */
function headingVersion(line: string): string | null {
  const m = line.match(/^##\s+(.+)$/); // level 2 only — `### …` won't match
  if (!m) return null;
  return m[1]
    .trim()
    .split(/\s+/)[0] // first token, before any ` - date`
    .replace(/^\[|\]$/g, "") // strip [ ]
    .replace(/^v/i, ""); // strip a leading v
}

/** Return the notes body for `version` (without its heading), or null if the
 *  changelog has no section for it. */
export function extractReleaseNotes(
  changelog: string,
  version: string,
): string | null {
  const lines = changelog.split("\n");

  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (headingVersion(lines[i]) === version) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return null;

  let end = lines.length;
  for (let i = start; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) {
      end = i;
      break;
    }
  }

  const body = lines.slice(start, end).join("\n").trim();
  return body || null;
}

if (import.meta.main) {
  const version = process.argv[2];
  if (!version) die("usage: bun scripts/changelog.ts <version>");
  const changelog = join(import.meta.dir, "..", "CHANGELOG.md");
  const notes = extractReleaseNotes(await Bun.file(changelog).text(), version);
  // No section is not an error — a release without notes is still a release.
  if (notes) console.log(notes);
}
