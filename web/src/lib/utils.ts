import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * Resolve a file in `public/` against the deployment's base path. Root-absolute
 * URLs would 404 on GitHub Pages, which serves this site under `/terminal/`;
 * Vite rewrites `BASE_URL` per build, so the same call works on both hosts.
 */
export function asset(path: string) {
  return `${import.meta.env.BASE_URL}${path.replace(/^\//, "")}`
}
