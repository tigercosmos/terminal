import { Link } from '@tanstack/react-router'

const AUTHOR_URL = 'https://github.com/tigercosmos'
const KERO_URL = 'https://kero.sh'
const GITHUB_URL = 'https://github.com/tigercosmos/terminal'

export function SiteFooter() {
  return (
    <footer className="text-[13px] text-muted-foreground">
      Built by{' '}
      <a
        href={AUTHOR_URL}
        target="_blank"
        rel="noreferrer"
        className="text-foreground transition-colors hover:text-brand"
      >
        @tigercosmos
      </a>{' '}
      and the{' '}
      <a
        href={KERO_URL}
        target="_blank"
        rel="noreferrer"
        className="text-foreground transition-colors hover:text-brand"
      >
        Kero
      </a>{' '}
      team ·{' '}
      <a
        href={GITHUB_URL}
        target="_blank"
        rel="noreferrer"
        className="text-foreground transition-colors hover:text-brand"
      >
        GitHub
      </a>{' '}
      ·{' '}
      <Link
        to="/changelog"
        className="text-foreground transition-colors hover:text-brand"
      >
        Changelog
      </Link>{' '}
      · © 2026
    </footer>
  )
}
