# Terminal — website

Landing page for **Terminal**, the native terminal workspace for macOS.

## Stack

- [TanStack Start](https://tanstack.com/start) (React 19 + Vite 8)
- [Tailwind CSS v4](https://tailwindcss.com)
- [shadcn/ui](https://ui.shadcn.com) with **Base UI** primitives (`@base-ui/react`)
- Deployed to [Cloudflare Workers](https://developers.cloudflare.com/workers/)
  via [`@cloudflare/vite-plugin`](https://developers.cloudflare.com/workers/vite-plugin/)

## Develop

```sh
bun install
bun run dev        # http://localhost:3000 (runs in the Workers runtime)
bun run typecheck  # tsc --noEmit
```

## Deploy (Cloudflare Workers)

```sh
bunx wrangler login   # once, to authenticate
bun run deploy        # vite build → wrangler deploy
```

`bun run build` outputs the Worker + client assets to `dist/`; the
`@cloudflare/vite-plugin` generates the deploy config, so plain `wrangler deploy`
picks it up. `bun run preview` serves the built Worker locally.

Config lives in [`wrangler.jsonc`](wrangler.jsonc) (worker name, compatibility
flags). To serve from your own domain, uncomment the `routes` entry there once the zone
is on Cloudflare. Run `bun run cf-typegen` after adding any bindings.

## Deploy (GitHub Pages)

This is the deploy that is actually live, at
<https://tigercosmos.github.io/terminal>. `.github/workflows/pages.yml` runs on
every push to `main` that touches `web/`, and publishes `dist/client`.

The one difference from the Worker build is `SITE_BASE`, which carries the
subpath a Pages project site is served from:

```sh
SITE_BASE=/terminal/ bun run build   # what CI runs
```

That prefix reaches asset URLs through Vite's `base`, router links through
`basepath` in [`src/router.tsx`](src/router.tsx), and files in `public/` through
the `asset()` helper in [`src/lib/utils.ts`](src/lib/utils.ts) — use it rather
than a root-absolute `/foo.png`, which resolves off the base and 404s. Pages has
no server, so `/` is prerendered when `SITE_BASE` is set; the Worker still
renders it per request, which is what lets the download button follow the
appcast.

To preview the subpath locally, serve the build from a directory named
`terminal`:

```sh
SITE_BASE=/terminal/ bun run build
mkdir -p /tmp/pages && cp -R dist/client /tmp/pages/terminal
cd /tmp/pages && python3 -m http.server 8765   # http://localhost:8765/terminal/
```

## Notes

- The theme lives in [`src/styles/app.css`](src/styles/app.css) — a GitHub-dark
  palette that mirrors the macOS app (`terminal/Theme.swift`).
- Add more components with `bunx shadcn@latest add <name>` — the project is
  already configured for Base UI (`components.json` → `"style": "base-nova"`).
- The download URL and version live in the `LATEST` constant at the top of
  [`src/routes/index.tsx`](src/routes/index.tsx). Bump it on each release.
- The hero product shot is [`public/terminal-screenshot.png`](public/terminal-screenshot.png)
  (a real app screenshot with transparent padding + shadow) — swap the file to
  update it.
