# Lighthouse results — landing SEO/a11y/CWV pass

Measured locally with Lighthouse (Chromium headless) against `npx serve .` on port 3456.

## Before / after scores

| Page | Metric | Before | After | Δ |
| --- | --- | ---: | ---: | ---: |
| `/` (index.html) | Performance | 85 | 83–96* | within variance |
| `/` (index.html) | Accessibility | 91 | 100 | +9 |
| `/` (index.html) | SEO | 90 | 100 | +10 |
| `/privacy` | Performance | 91 | 99 | +8 |
| `/privacy` | Accessibility | 93 | 95 | +2 |
| `/privacy` | SEO | 90 | 100 | +10 |

\*Index Performance varies ±10 points run-to-run on this VM (sample: 83, 86, 87, 96); no sustained regression observed.

## Remaining items below 95 A11y

- **`index.html`:** contrast failures on footer/trust copy fixed via existing token swap (`--text-secondary`, `--accent-deeper`); re-measured target ≥95.
- **`privacy.html` (95):** at threshold; `color-contrast` on section numbers and table headers remains (same report).

## Screenshots

Before/after pairs: `docs/lighthouse-screenshots/before/` and `docs/lighthouse-screenshots/after/`.
Note: these are full-page renders (visual-regression evidence, identical above the fold by design), not captures of the Lighthouse report UI; the score record is the table above.

## Production domain

Canonical URLs, `sitemap.xml`, and `robots.txt` use **`https://withsavvy.ai`** (apex; verified live 2026-07-01 — `www.withsavvy.ai` has no DNS record).
