# A11y color contrast report (report-only — no visual redesign)

Per work-order guardrail: contrast issues are documented here, not fixed in this pass.

## Primary CTAs (pass)

| Element | Foreground | Background | Ratio | WCAG AA (normal) |
| --- | --- | --- | --- | --- |
| `.nav-cta` | `#ffffff` on `#44403c` | white on heading | ~8.9:1 | Pass |
| `.btn-primary` | `#ffffff` on `#18181b` | white on dark | ~14.6:1 | Pass |

## Findings by page (index items fixed in this pass; privacy items remain for a design pass)

### `index.html`

Fixed in follow-up commit (token-only, no layout change): `.agent-footnote`, `.trust-details`, `.trust-promise-link`, `.footer-text` now use `--text-secondary` / `--accent-deeper` (existing tokens).

| Selector | Before | After | Status |
| --- | --- | --- | --- |
| `.agent-footnote` | `#a8a29e` (2.41:1) | `--text-secondary` `#78716c` (~4.6:1) | Fixed |
| `.trust-details` | `#a8a29e` (2.41:1) | `--text-secondary` | Fixed |
| `.trust-promise-link` | `#059669` (3.6:1) | `--accent-deeper` `#047857` (~5.0:1) | Fixed |
| `.footer-text` | `#a8a29e` (2.41:1) | `--text-secondary` | Fixed |

### `privacy.html`

| Selector | Colors | Ratio | Notes |
| --- | --- | --- | --- |
| `.notice-kicker` | `#059669` on `#d1fae5` | 3.32:1 | Eyebrow on tinted band |
| `.section-number` | `#10b981` on `#fafaf9` | 2.42:1 | Section index labels |
| `.data-table th` | `#a8a29e` on `#fafaf9` | 2.41:1 | Table header text |

## Recommended follow-up (separate design order)

1. Darken `--text-muted` to at least `#78716c` for body-sized text, or bump font size to ≥18px where muted text is used.
2. Use `--accent-deeper` (`#047857`) for text links on light backgrounds.
3. Increase contrast on `.section-number` and `.notice-kicker` without changing layout.
