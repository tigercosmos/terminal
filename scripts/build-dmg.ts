#!/usr/bin/env bun
//
// Builds the unsigned .dmg that a GitHub Release carries: a universal Release
// build, packaged with the app and an /Applications symlink.
//
// This is the download path that needs no credentials — no Developer ID, no
// notarization, no Sparkle key. `scripts/release.ts` is the signed one; see
// RELEASING.md for which is which.
//
// The release workflow runs this, and so can you when the runner image is
// unavailable and the .dmg has to be attached by hand:
//
//   bun scripts/build-dmg.ts
//   gh release upload v1.1 build/terminal-1.1.dmg
//
// Usage:
//   bun scripts/build-dmg.ts            # build, then package
//   bun scripts/build-dmg.ts --expect 1.1   # fail unless the app says 1.1
import { $ } from "bun";
import { appendFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { die, need, say } from "./lib";

// Run from the repo root regardless of where we were invoked.
process.chdir(join(import.meta.dir, ".."));

const args = process.argv.slice(2).filter((arg) => arg !== "--");
const expectIndex = args.indexOf("--expect");
const expected = expectIndex === -1 ? null : args[expectIndex + 1];
if (expectIndex !== -1 && !expected) die("--expect needs a version");
const unknownArg = args.find(
  (arg, i) => i !== expectIndex && i !== expectIndex + 1,
);
if (unknownArg) die(`unknown option: ${unknownArg}`);

const PROJECT = "terminal.xcodeproj";
const SCHEME = "terminal";
const BUILD_DIR = process.env.BUILD_DIR ?? "build";
const DERIVED_DATA = join(BUILD_DIR, "dd");

need("xcodebuild");
need("ditto");
need("hdiutil");
need("plutil");

// ---- 1. build ------------------------------------------------------------
// Unsigned, not ad-hoc: an ad-hoc signature plus ENABLE_HARDENED_RUNTIME trips
// Library Validation, which wants a Team ID match ad-hoc code cannot give, so
// dyld rejects the embedded Sparkle.framework and the app dies at launch. The
// Makefile builds unsigned for the same reason.
say("Building (Release, unsigned)…");
await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration Release \
  -destination ${"generic/platform=macOS"} -derivedDataPath ${DERIVED_DATA} \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`;

const app = join(DERIVED_DATA, "Build/Products/Release/Terminal.app");
if (!existsSync(app)) die(`built app not found at ${app}`);

// ---- 2. read the version off the build -----------------------------------
const appPlist = join(app, "Contents/Info.plist");
const version = (
  await $`plutil -extract CFBundleShortVersionString raw ${appPlist}`.text()
).trim();
if (!version) die("could not read CFBundleShortVersionString");
// A tag naming a version the project doesn't carry would publish a build whose
// release disagrees with its Info.plist, which is worse than not publishing.
if (expected && version !== expected) {
  die(`expected version ${expected}, but the build says ${version}`);
}

// ---- 3. package ----------------------------------------------------------
// hdiutil rather than create-dmg: create-dmg's arranged window needs Finder
// scripting, which is unreliable on a headless runner. A folder holding the
// app and an /Applications symlink installs the same way.
say(`Packaging terminal-${version}.dmg…`);
const staging = join(BUILD_DIR, "dmg");
const dmg = join(BUILD_DIR, `terminal-${version}.dmg`);
rmSync(staging, { recursive: true, force: true });
mkdirSync(staging, { recursive: true });
await $`ditto ${app} ${join(staging, "Terminal.app")}`;
await $`ln -s /Applications ${join(staging, "Applications")}`;
await $`hdiutil create -volname ${`Terminal ${version}`} -srcfolder ${staging} \
  -fs HFS+ -format UDZO -ov ${dmg}`;
if (!existsSync(dmg)) die("hdiutil did not produce a disk image");

// The workflow reads these back to name the release and find the file.
// Appended, not written: the file collects every output of the step.
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\ndmg=${dmg}\n`);
}

say(`Done. Unsigned — macOS will quarantine it on download.`);
console.log(`     version : ${version}`);
console.log(`     download: ${dmg}`);
