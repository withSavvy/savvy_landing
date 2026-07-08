# A11y color contrast report (report-only — no visual redesign)

Per work-order guardrail: contrast issues are documented here, not fixed in this pass.

## Primary CTAs (pass)

| Element | Foreground | Background | Ratio | WCAG AA (normal) |
| --- | --- | --- | --- | --- |
| `.nav-cta` | `#ffffff` on `#44403c` | white on heading | ~8.9:1 | Pass |
| `.btn-primary` | `#ffffff` on `#18181b` | white on dark | ~14.6:1 | Pass |

## Findings by page (token-only fixes — no layout change)

### `index.html`

Fixed in follow-up commit: `.agent-footnote`, `.trust-details`, `.trust-promise-link`, `.footer-text` now use `--text-secondary` / `--accent-deeper` (existing tokens).

| Selector | Before | After | Status |
| --- | --- | --- | --- |
| `.agent-footnote` | `#a8a29e` (2.41:1) | `--text-secondary` `#78716c` (~4.6:1) | Fixed |
| `.trust-details` | `#a8a29e` (2.41:1) | `--text-secondary` | Fixed |
| `.trust-promise-link` | `#059669` (3.6:1) | `--accent-deeper` `#047857` (~5.0:1) | Fixed |
| `.footer-text` | `#a8a29e` (2.41:1) | `--text-secondary` | Fixed |

### `privacy.html`

Fixed 2026-07-08: aligned `:root` tokens with `index.html` (`--text-secondary` `#78716c`, added `--accent-deeper` `#047857`).

| Selector | Before | After | Status |
| --- | --- | --- | --- |
| `.notice-kicker` | `--accent-dark` `#059669` on `#d1fae5` (3.32:1) | `--accent-deeper` `#047857` (~5.0:1) | Fixed |
| `.hero-eyebrow` | `--accent-dark` `#059669` on `#d1fae5` (3.32:1) | `--accent-deeper` `#047857` (~5.0:1) | Fixed |
| `.section-number` | `--accent` `#10b981` on `#fafaf9` (2.42:1) | `--accent-deeper` `#047857` (~5.0:1) | Fixed |
| `.data-table th` | `--text-muted` `#a8a29e` on `#fafaf9` (2.41:1) | `--text-secondary` `#78716c` (~4.6:1) | Fixed |

## Domain alignment

Canonical URLs, `sitemap.xml`, `robots.txt`, and JSON-LD use **`https://withsavvy.ai`** (apex). `www.withsavvy.ai` has no DNS — pending Cloudflare custom-domain setup (`ht-www-dns` in workspace bank).
