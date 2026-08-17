# Savvy Landing

**Marketing site for Savvy** — static landing page. Loosely connected to the main [Savvy](https://github.com/Sara3/savvy) app (credit card benefit tracker); this repo is **standalone** and has its **own GitHub repository**.

- **Live site (Cloudflare Workers):** https://withsavvy.ai/
- **Waitlist API (Render):** backend in this repo deploys to e.g. https://savvy-api-1kov.onrender.com (or your own Render service).

## What’s in this repo

- **Root:** static marketing page (`index.html`, styles, scripts). No build step; open `index.html` locally or deploy the repo as-is.
- **Assets:** images in `Assets/` (hero, etc.).
- **backend/:** small Node/Express server for waitlist signups (`POST /api/signup`). Deploy to Render (or similar) separately from the static site.

## Run locally

1. **Landing page (static):**  
   Open `index.html` in a browser, or serve the repo root:
   ```bash
   npx serve .
   ```
   Then open http://localhost:3000 (or the port `serve` prints).

2. **Backend (optional, for form submit):**  
   ```bash
   cd backend && npm install && npm start
   ```
   By default it runs on port 3000. The landing page must point the signup form at this URL (or your deployed API URL) for waitlist to work.

## Deploy

### Cloudflare Workers (static site)

Production (`https://withsavvy.ai/`) is served by Cloudflare Workers, not GitHub Pages. `wrangler.jsonc` defines two environments:

- `staging` → `savvylanding-staging`
- `production` → `savvylanding`

The GitHub Actions workflow (`.github/workflows/deploy.yml`) deploys to production automatically on push to `main` (requires the `CLOUDFLARE_API_TOKEN` repo secret; the workflow can also be run manually via `workflow_dispatch`). To deploy manually:

```bash
npx wrangler@4 deploy --env production
```

### Custom domain (e.g. Clark)

The CNAME for `withsavvy.ai` is already configured in DNS. To point a different custom domain at this Worker, add it in the Cloudflare dashboard under **Workers & Pages → savvylanding → Settings → Domains & Routes**.

### Backend (waitlist API)

- **Render:** Use `backend/render.yaml` (or connect the `backend/` directory as a separate Render service). Set env (e.g. `PORT`) as needed.
- **CORS:** `backend/server.js` already allows origins for GitHub Pages and common local ports; add your custom domain (e.g. Clark) to the `origin` list if the landing page is served from that domain.

## Repo vs main Savvy app

- **This repo:** marketing site only. Its own repo, its own README, its own deploy (Pages + optional backend).
- **Main app:** [Savvy](https://github.com/Sara3/savvy) — backend + frontend for the product; separate repo(s).

## See also

- **Analytics:** `ANALYTICS.md` — GA4 and optional page-view logging.
- **Main Savvy:** https://github.com/Sara3/savvy
