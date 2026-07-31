import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'
import { asset, cn } from '@/lib/utils'

export const Route = createFileRoute('/')({
  component: Home,
  // Fetched per request (SSR) so the page always advertises the newest release.
  loader: () => fetchLatestRelease(),
  staleTime: 5 * 60 * 1000,
})

type Release = { version: string; minSystem: string; dmg: string }

// No Sparkle release host yet. Point this at the origin serving your archives
// and appcast once one exists; until then the download comes from GitHub
// Releases, where the release workflow attaches an unsigned .dmg per tag.
const RELEASES_ORIGIN = ''
const APPCAST_URL = `${RELEASES_ORIGIN}/appcast.xml`
const GITHUB_URL = 'https://github.com/tigercosmos/terminal'
const LATEST_RELEASE_API = 'https://api.github.com/repos/tigercosmos/terminal/releases/latest'
// No Homebrew tap yet; set this once a cask is published.
const BREW_COMMAND = ''

// Shown only if the release can't be looked up; kept current so downloads still work.
const FALLBACK: Release = {
  version: '0.2.0',
  minSystem: '15.6',
  dmg: `${GITHUB_URL}/releases/download/v0.2.0/terminal-0.2.0.dmg`,
}

/**
 * Pick the newest release out of the Sparkle appcast — the item with the highest
 * build number (`sparkle:version`). The site links the notarized `.dmg`, which
 * sits beside the `.zip` update enclosure at `terminal-<version>.dmg`.
 */
function parseLatestRelease(xml: string): Release | null {
  let best: { build: number; version: string; minSystem: string } | null = null
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const version = item
      .match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1]
      ?.trim()
    if (!version) continue
    const build = Number(
      item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim() ?? '0',
    )
    const minSystem = item
      .match(/<sparkle:minimumSystemVersion>([^<]+)<\/sparkle:minimumSystemVersion>/)?.[1]
      ?.trim()
    if (!best || build > best.build) {
      best = { build, version, minSystem: minSystem || FALLBACK.minSystem }
    }
  }
  if (!best) return null
  return {
    version: best.version,
    minSystem: best.minSystem,
    dmg: `${RELEASES_ORIGIN}/terminal-${best.version}.dmg`,
  }
}

// The site runs as a Cloudflare Worker; cache these lookups at the edge so we
// don't refetch on every render. `cf` isn't part of the DOM RequestInit type,
// hence the cast at each call site.
const edgeCached = (seconds: number) =>
  ({
    signal: AbortSignal.timeout(2500),
    cf: { cacheTtl: seconds, cacheEverything: true },
  }) as RequestInit & { cf: { cacheTtl: number; cacheEverything: boolean } }

/**
 * The newest GitHub Release that has a `.dmg` attached — the download path for
 * this fork, since it has no Sparkle host. The API reports no deployment
 * target, so the minimum system comes from FALLBACK.
 */
async function fetchLatestGitHubRelease(): Promise<Release> {
  try {
    const res = await fetch(LATEST_RELEASE_API, {
      ...edgeCached(300),
      // GitHub rejects API requests without a User-Agent.
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'terminal-website' },
    })
    if (!res.ok) return FALLBACK
    const release = (await res.json()) as {
      tag_name?: string
      assets?: { name?: string; browser_download_url?: string }[]
    }
    const dmg = release.assets?.find((a) => a.name?.endsWith('.dmg'))?.browser_download_url
    if (!dmg) return FALLBACK
    return {
      version: (release.tag_name ?? FALLBACK.version).replace(/^v/, ''),
      minSystem: FALLBACK.minSystem,
      dmg,
    }
  } catch {
    return FALLBACK
  }
}

async function fetchLatestRelease(): Promise<Release | null> {
  // With a Sparkle host, the appcast is authoritative — it names the build the
  // in-app updater would install. Without one, GitHub Releases is the source.
  if (!RELEASES_ORIGIN) return fetchLatestGitHubRelease()
  try {
    // Matches the appcast's own 5-min max-age.
    const res = await fetch(APPCAST_URL, edgeCached(300))
    if (!res.ok) return FALLBACK
    return parseLatestRelease(await res.text()) ?? FALLBACK
  } catch {
    return FALLBACK
  }
}

/* ------------------------------------------------------------------ */

type Row = { name: string; detail: string }

// Keep this list in step with the "Beyond Kero" section of the repository
// README — the two are the only places the fork's own work is written down.
const FEATURES: { group: string; rows: Row[] }[] = [
  {
    group: 'beyond kero',
    rows: [
      {
        name: 'Compare any revision',
        detail:
          'Cmd+Shift+C puts a branch, a commit, or any revision git understands beside your working tree — read the diff, keep editing your side, blame a line, revert a file',
      },
      {
        name: 'Files follow you over ssh',
        detail:
          "connect to another machine and the Files panel shows that machine's files — folders expand and files open read-only over the connection you already have, and a host that would need a password says so instead of hanging",
      },
      {
        name: 'Files that open instantly',
        detail:
          'switching back to an open file keeps its undo history instead of rebuilding the editor, and a large one no longer stalls as you scroll',
      },
      {
        name: 'Hardened against untrusted input',
        detail:
          "a folder you open cannot make its own git config run commands, links that leave the browser ask first, and saved scrollback is yours to read alone",
      },
      {
        name: 'Builds without ceremony',
        detail:
          'make build, run, test, install — unsigned by default, so it launches without a Developer ID',
      },
    ],
  },
  {
    group: 'projects & sessions',
    rows: [
      {
        name: 'Projects, not windows',
        detail: 'each repo is a project in the sidebar — Cmd+1–9 switches, Cmd+N adds one',
      },
      {
        name: 'Sessions per project',
        detail:
          'open as many terminal tabs as a project needs with Cmd+T, each with its own directory and scrollback',
      },
      {
        name: 'Split panes',
        detail:
          'Cmd+D splits right, Cmd+Shift+D splits down, Opt+Cmd+arrows moves focus between panes',
      },
      {
        name: 'Restored on relaunch',
        detail:
          'quit and reopen: projects, tabs, and pane layout come back, each shell fresh beneath its previous scrollback',
      },
      {
        name: 'Command palette',
        detail: 'Cmd+P to jump to any project or session, or run any command',
      },
    ],
  },
  {
    group: 'review & ship',
    rows: [
      {
        name: 'Git panel',
        detail:
          'stage, unstage, discard, and commit — amend included — beside the shell that made the changes',
      },
      {
        name: 'Inline diffs',
        detail: 'click a changed file to read its diff in place, without leaving the window',
      },
      {
        name: 'Branch work',
        detail:
          'switch or create a branch, fetch, fast-forward pull, push, publish a new upstream, or stash',
      },
      {
        name: 'Files panel',
        detail:
          'browse the working tree, open a file, edit it with tree-sitter highlighting, Cmd+S to save',
      },
      {
        name: 'Session info',
        detail:
          'the processes running under a session and the TCP ports they are listening on',
      },
    ],
  },
  {
    group: 'the terminal itself',
    rows: [
      {
        name: 'Your shell, unchanged',
        detail: 'zsh, fish, or bash exactly as you configured it — prompt, aliases, dotfiles and all',
      },
      {
        name: 'Built on libghostty',
        detail: "Ghostty's terminal core, embedded and hosted natively by terminal",
      },
      {
        name: 'Desktop notifications',
        detail:
          'a bell in an unfocused session, or a notification escape from a long-running command, reaches Notification Center',
      },
      {
        name: 'Progress reports',
        detail: 'OSC 9;4 progress shows as a slim bar above the terminal, error and pause states included',
      },
      {
        name: 'Fonts',
        detail:
          'ships with JetBrains Mono and Nerd Font symbols; swap in any monospace family and size, or zoom with Cmd+Plus and Cmd+Minus',
      },
      {
        name: 'No update checks',
        detail:
          'Sparkle is built in but never starts — this fork ships no update feed and no signing key, so nothing checks in; download the newest release or pull and rebuild to move up',
      },
    ],
  },
]

/**
 * Modifiers are spelled out rather than set as ⌘/⇧/⌥/⌃. Geist Mono ships no
 * subset covering U+2318, U+21E7, U+2325, or U+2303, so those glyphs always
 * fall back to another family mid-word — thinner, differently sized, and off
 * the mono grid — and go missing entirely on most non-Apple systems.
 */
const SHORTCUTS: Row[] = [
  { name: 'Cmd+N', detail: 'new project' },
  { name: 'Cmd+T', detail: 'new session' },
  { name: 'Cmd+W', detail: 'close the focused pane' },
  { name: 'Cmd+1–9', detail: 'switch project' },
  { name: 'Ctrl+1–9', detail: 'switch tab' },
  { name: 'Ctrl+Tab', detail: 'open the tab switcher' },
  { name: 'Cmd+P', detail: 'command palette' },
  { name: 'Cmd+D / Cmd+Shift+D', detail: 'split right / split down' },
  { name: 'Opt+Cmd+arrows', detail: 'focus the pane in that direction' },
  { name: 'Cmd+[ / Cmd+]', detail: 'cycle pane focus' },
  { name: 'Cmd+Shift+Return', detail: 'zoom the focused pane' },
  { name: 'Ctrl+Cmd+arrows / =', detail: 'resize / equalize panes' },
  { name: 'Cmd+B / Cmd+Shift+B', detail: 'toggle the left / right sidebar' },
  { name: 'Cmd+Shift+G / E / I', detail: 'git / files / info panel' },
  { name: 'Cmd+Shift+C', detail: 'compare against a branch or commit' },
  { name: 'Cmd+F / Cmd+G', detail: 'find / find next' },
  { name: 'Cmd+K', detail: 'clear the terminal' },
  {
    name: 'Cmd+Plus (or Cmd+=) / Cmd+Minus / Cmd+0',
    detail:
      'zoom the terminal text in, out, or back to its default size — the page, in a browser pane',
  },
  { name: 'Cmd+S', detail: 'save the open file' },
]

const FAQ: { q: string; a: ReactNode }[] = [
  {
    q: 'How is this different from Kero?',
    a: (
      <>
        Terminal is a fork of{' '}
        <a
          href="https://kero.sh"
          target="_blank"
          rel="noreferrer"
          className="text-foreground underline underline-offset-4 hover:text-brand"
        >
          Kero
        </a>{' '}
        that leans harder on reviewing what coding agents write. The Compare
        panel is the main addition: any branch or commit beside your working
        tree, editable, with blame and revert. The Files panel also follows a
        terminal over ssh, showing the host you connected to. Opening files got
        faster, the
        paths that handle a repository's own data were hardened against
        untrusted input, and a Makefile replaced the build incantations. It
        tracks Kero and merges upstream work back in, so everything Kero does is
        still here. The practical difference is distribution — Kero ships
        notarized builds and a Homebrew cask; this fork has no signing key, so
        its .dmg is unsigned — macOS quarantines it until you clear the flag,
        and there is no in-app updater.
      </>
    ),
  },
  {
    q: 'Is terminal free?',
    a: 'Yes. Free to download, no subscription, no account.',
  },
  {
    q: 'Does it replace my shell?',
    a: 'No. terminal hosts the shell you already run and leaves your prompt, aliases, and dotfiles untouched. The terminal underneath is libghostty, the same core as Ghostty.',
  },
  {
    q: 'Does it collect any data?',
    a: 'No telemetry, no analytics. The only network call Terminal makes is the update check, and that is off until an update feed is configured.',
  },
  {
    q: 'What happens to my sessions when I quit?',
    a: 'Projects, tabs, and pane layout come back on relaunch. Each terminal reopens as a fresh shell in its old directory, with the previous scrollback restored above a "Session Contents Restored" divider.',
  },
  {
    q: 'Is this an IDE?',
    a: 'No — the terminal stays the center of gravity. The git and files panels exist so you can review and ship what happens in the terminal without switching to an editor.',
  },
]

/* ------------------------------------------------------------------ */

function Home() {
  const latest = Route.useLoaderData()
  return (
    <SiteLayout
      headerContent={
        <>
          <p className="text-foreground/70">
            Your terminal, with the{' '}
            <span className="text-brand">whole project</span> around it.
            <span
              aria-hidden
              className="ml-[5px] inline-block h-[1.05em] w-[7px] animate-caret rounded-[1px] bg-brand align-[-0.15em] motion-reduce:animate-none"
            />
          </p>
          <p className="mt-3.5 text-muted-foreground">
            A native macOS workspace built around the terminal — projects, persistent
            sessions, files, and git in one window.
            <br />
            Free, no telemetry, no subscription.
          </p>
        </>
      }
    >
      <section className="flex flex-col gap-3.5">
        <div className="flex flex-wrap items-center gap-2.5">
          {latest ? (
            <a
              href={latest.dmg}
              download
              className="inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand"
            >
              <span className="i-mingcute-apple-fill size-4 shrink-0" />
              Download .dmg
            </a>
          ) : (
            <a
              href={`${GITHUB_URL}#install`}
              className="inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand"
            >
              <span className="i-mingcute-apple-fill size-4 shrink-0" />
              Build from source
            </a>
          )}
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand"
          >
            <span className="i-mingcute-github-fill size-4 shrink-0" />
            GitHub
          </a>
        </div>
        {BREW_COMMAND ? <CopyCommand command={BREW_COMMAND} /> : null}
        {/* The .dmg is unsigned, so macOS quarantines it and refuses to open the
            app until the flag is cleared. Say so where the download is, not
            buried in the FAQ. */}
        {latest ? (
          <div className="flex flex-col gap-1.5 text-[13px] text-muted-foreground">
            <span>
              Unsigned build — after moving Terminal to Applications, clear the
              quarantine flag once:
            </span>
            <CopyCommand command="xattr -dr com.apple.quarantine /Applications/Terminal.app" />
          </div>
        ) : null}
        <div className="flex flex-wrap items-center gap-2 text-[13px] text-muted-foreground">
          {latest ? <Pill>v{latest.version}</Pill> : null}
          {latest ? <Pill>macOS {latest.minSystem}+</Pill> : null}
          <Pill>free & open-source</Pill>
        </div>
      </section>

      <figure className="m-0 flex flex-col gap-2">
        <img
          src={asset('terminal-screenshot.png')}
          alt="terminal showing a project's terminal session with the git panel open"
          width={2286}
          height={1568}
          className="block w-full rounded-lg border border-border bg-card"
        />
        <figcaption className="text-[13px] text-muted-foreground">
          Projects, tabs, the info panel open beside it
        </figcaption>
      </figure>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>Features</SectionHeading>
        <div className="flex flex-col gap-7">
          {FEATURES.map((section) => (
            <div key={section.group} className="flex flex-col gap-3">
              <h3 className="flex items-center gap-3 text-xs font-normal tracking-[0.04em] text-foreground/60 after:h-px after:flex-1 after:bg-border after:content-['']">
                {section.group}
              </h3>
              <ul className="grid list-none gap-2 p-0">
                {section.rows.map((row) => (
                  <DefinitionRow key={row.name} {...row} />
                ))}
              </ul>
            </div>
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>Shortcuts</SectionHeading>
        <ul className="grid list-none gap-2 p-0">
          {SHORTCUTS.map((row) => (
            <DefinitionRow key={row.name} {...row} />
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>FAQ</SectionHeading>
        <div className="flex flex-col gap-2">
          {FAQ.map((item) => (
            <details key={item.q} className="group border-b border-border">
              <summary className="flex cursor-pointer list-none items-baseline gap-2.5 py-2 text-foreground transition-colors hover:text-brand [&::-webkit-details-marker]:hidden">
                <span
                  aria-hidden
                  className="flex-none text-muted-foreground before:content-['+'] group-open:before:content-['–']"
                />
                {item.q}
              </summary>
              <p className="mb-3 ml-5 text-muted-foreground">{item.a}</p>
            </details>
          ))}
        </div>
      </section>
    </SiteLayout>
  )
}

/* ------------------------------------------------------------------ */

function SectionHeading({ children }: { children: ReactNode }) {
  return (
    <h2 className="text-[13px] font-normal tracking-[0.04em] text-muted-foreground">
      {children}
    </h2>
  )
}

/**
 * The Homebrew one-liner with a copy button, sharing the download button's
 * chrome. The command stays selectable so it's still usable if the Clipboard
 * API isn't available (insecure context, denied permission).
 */
function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false)
  const commandRef = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(true)
    } catch {
      // Clipboard denied (insecure context, permissions policy). Select the
      // command so ⌘C still works — a button that does nothing reads as broken.
      const node = commandRef.current
      if (!node) return
      const range = document.createRange()
      range.selectNodeContents(node)
      const selection = window.getSelection()
      selection?.removeAllRanges()
      selection?.addRange(range)
    }
  }

  return (
    <div className="flex max-w-full items-stretch self-start overflow-hidden rounded-[9px] border border-border bg-card">
      <code className="flex min-w-0 items-center gap-2 overflow-x-auto px-4 py-[7px] whitespace-pre">
        <span aria-hidden className="shrink-0 text-muted-foreground select-none">
          $
        </span>
        <span ref={commandRef}>{command}</span>
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label={`Copy "${command}" to the clipboard`}
        className="inline-flex shrink-0 items-center gap-2 border-l border-border px-3.5 text-muted-foreground transition-colors hover:bg-brand/8 hover:text-brand"
      >
        <span
          aria-hidden
          className={cn(
            'size-4 shrink-0',
            copied ? 'i-mingcute-check-line' : 'i-mingcute-copy-2-line',
          )}
        />
        <span aria-live="polite" className="max-[420px]:sr-only">
          {copied ? 'Copied' : 'Copy'}
        </span>
      </button>
    </div>
  )
}

function Pill({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center rounded-[6px] border border-border px-2 py-[3px]">
      {children}
    </span>
  )
}

/** A label/description pair — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="group grid grid-cols-[190px_1fr] items-baseline gap-4 max-[560px]:grid-cols-1 max-[560px]:gap-0.5">
      <span className="text-foreground transition-colors group-hover:text-brand">
        {name}
      </span>
      <span className="text-muted-foreground transition-colors group-hover:text-foreground">
        {detail}
      </span>
    </li>
  )
}
