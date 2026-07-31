import { defineConfig } from 'vite'
import { cloudflare } from '@cloudflare/vite-plugin'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// GitHub Pages serves a project site under a subpath (`/terminal/`), while the
// Cloudflare Worker serves from the root. SITE_BASE carries that prefix so the
// same source builds for both; unset, everything behaves exactly as before.
const base = process.env.SITE_BASE ?? '/'
const isPages = base !== '/'

export default defineConfig({
  base,
  server: { port: 3000 },
  resolve: { tsconfigPaths: true },
  plugins: [
    cloudflare({ viteEnvironment: { name: 'ssr' } }),
    tailwindcss(),
    tanstackStart({
      prerender: {
        enabled: true,
        autoStaticPathsDiscovery: false,
        crawlLinks: false,
      },
      pages: [
        // '/' is prerendered only for Pages, which has no server to run the
        // route's loader. The Worker keeps rendering it per request so the
        // download button can follow the appcast instead of a build-time copy.
        ...(isPages ? [{ path: '/', prerender: { enabled: true } }] : []),
        { path: '/changelog', prerender: { enabled: true } },
      ],
      sitemap: { enabled: false },
    }),
    viteReact(),
  ],
})
