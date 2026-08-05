#!/usr/bin/env bash
# Verifies the Cloudflare `_headers` file:
#   1. it exists and is not dropped by the .assetsignore allowlist;
#   2. it sets the required security headers on every published page;
#   3. its Content-Security-Policy still covers every external origin that the
#      published HTML actually references.
#
# (3) is the part with teeth. Adding e.g. an analytics <script src> or a CDN
# stylesheet to a published page fails this check until either the CSP is
# widened to match or the origin is classified as navigation-only below. That
# is deliberate: a CSP that silently drifts out of date breaks the live
# marketing site, which is worse than having no CSP at all.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEADERS_FILE="$REPO_ROOT/_headers"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fail=0
note_fail() { echo "FAIL  $*"; fail=1; }
note_ok() { echo "OK    $*"; }

# --- 1. the file exists and survives .assetsignore ---------------------------

if [ ! -f "$HEADERS_FILE" ]; then
  echo "FAIL  _headers is missing — no security headers would be applied."
  exit 1
fi
note_ok "_headers exists"

cp "$REPO_ROOT/.assetsignore" "$SCRATCH/.gitignore"
git -C "$SCRATCH" init -q

# `_headers` must NOT be un-ignored in .assetsignore. Wrangler reads it off
# disk as configuration no matter what .assetsignore says, and separately
# hard-codes `/_headers` as an always-ignored upload pattern. A trailing
# `!/_headers` negation in .assetsignore overrides that built-in and publishes
# the config file itself at /_headers — it does not "help Cloudflare find it".
if git -C "$SCRATCH" check-ignore --no-index -q -- "_headers"; then
  note_ok "_headers stays config-only (not un-ignored into the published assets)"
else
  note_fail "_headers is un-ignored in .assetsignore — that publishes the config file at /_headers instead of helping Cloudflare read it; remove the '!/_headers' line"
fi

# The header block that applies to every page. Cloudflare's format is a path
# rule on its own line followed by indented `Name: value` lines.
if ! grep -qE '^/\*[[:space:]]*$' "$HEADERS_FILE"; then
  note_fail "_headers has no '/*' rule — headers would not apply site-wide"
  exit "$fail"
fi
note_ok "_headers has a site-wide '/*' rule"

# Everything indented under the last path rule. This site only has one rule;
# if that ever changes, this check should be revisited.
RULES="$(sed -n '/^\/\*[[:space:]]*$/,$p' "$HEADERS_FILE" | grep -E '^[[:space:]]+[A-Za-z-]+:' || true)"

header_value() {
  # header_value <name> -> the value, or empty if absent
  printf '%s\n' "$RULES" \
    | grep -iE "^[[:space:]]+$1:" \
    | head -n1 \
    | sed -E "s/^[[:space:]]+[A-Za-z-]+:[[:space:]]*//"
}

# --- 2. required headers -----------------------------------------------------

assert_header_matches() {
  # assert_header_matches <header> <extended-regex> <human description>
  local name="$1" pattern="$2" desc="$3" value
  value="$(header_value "$name")"
  if [ -z "$value" ]; then
    note_fail "$name is not set"
  elif printf '%s' "$value" | grep -qiE "$pattern"; then
    note_ok "$name: $value"
  else
    note_fail "$name does not $desc (got: $value)"
  fi
}

assert_header_matches "X-Content-Type-Options" '^nosniff$' "equal 'nosniff'"
assert_header_matches "Referrer-Policy" '^strict-origin-when-cross-origin$' \
  "equal 'strict-origin-when-cross-origin'"
assert_header_matches "X-Frame-Options" '^DENY$' "equal 'DENY'"
assert_header_matches "Strict-Transport-Security" 'includeSubDomains' \
  "include includeSubDomains"

# HSTS max-age must be at least one year.
HSTS="$(header_value "Strict-Transport-Security")"
HSTS_MAX_AGE="$(printf '%s' "$HSTS" | grep -oiE 'max-age=[0-9]+' | head -n1 | cut -d= -f2 || true)"
if [ -n "$HSTS_MAX_AGE" ] && [ "$HSTS_MAX_AGE" -ge 31536000 ]; then
  note_ok "Strict-Transport-Security max-age=$HSTS_MAX_AGE (>= 1 year)"
else
  note_fail "Strict-Transport-Security max-age is missing or under 1 year (got: ${HSTS_MAX_AGE:-none})"
fi

CSP="$(header_value "Content-Security-Policy")"
if [ -z "$CSP" ]; then
  note_fail "Content-Security-Policy is not set"
else
  note_ok "Content-Security-Policy is set"
  for directive in "default-src" "base-uri" "object-src" "form-action" "frame-ancestors"; do
    if printf '%s' "$CSP" | grep -qE "(^|; *)$directive "; then
      note_ok "CSP has $directive"
    else
      note_fail "CSP is missing $directive"
    fi
  done
  # Clickjacking cover for browsers that honour CSP over X-Frame-Options.
  if printf '%s' "$CSP" | grep -qE "frame-ancestors 'none'"; then
    note_ok "CSP sets frame-ancestors 'none'"
  else
    note_fail "CSP does not set frame-ancestors 'none'"
  fi
fi

# --- 3. the CSP still covers what the published HTML loads -------------------

# Origins that appear in the HTML but are NOT subresource loads, so they need
# no CSP allowance. Anything here is a deliberate, reviewed classification.
#   withsavvy.ai        <link rel=canonical> / og:url — first party, 'self'
#   app.withsavvy.ai    <a href> navigation to the app (CSP does not gate nav)
#   plaid.com           <a href> navigation, privacy.html
#   my.plaid.com        <a href> navigation, privacy.html
#   www.w3.org          SVG XML namespace inside the data: favicon, not a fetch
#   schema.org          JSON-LD @context string, not a fetch
#   localhost           dev-only API fallback; the deployed host is never
#                       localhost, so this branch is dead in production
NON_SUBRESOURCE_ORIGINS=(
  "https://withsavvy.ai"
  "https://app.withsavvy.ai"
  "https://plaid.com"
  "https://my.plaid.com"
  "http://www.w3.org"
  "https://schema.org"
  "http://localhost"
)

# Scan exactly the pages .assetsignore actually publishes, so a newly published
# page is covered automatically.
published_html=()
for f in "$REPO_ROOT"/*.html; do
  rel="$(basename "$f")"
  if ! git -C "$SCRATCH" check-ignore --no-index -q -- "$rel"; then
    published_html+=("$f")
  fi
done

if [ "${#published_html[@]}" -eq 0 ]; then
  note_fail "no published HTML files found — the allowlist scan is broken"
else
  note_ok "scanning ${#published_html[@]} published HTML file(s) for external origins"
fi

origins="$(grep -ohiE 'https?://[a-zA-Z0-9._-]+' "${published_html[@]}" | sort -u)"

while IFS= read -r origin; do
  [ -n "$origin" ] || continue
  skip=0
  for known in "${NON_SUBRESOURCE_ORIGINS[@]}"; do
    if [ "$origin" = "$known" ]; then skip=1; break; fi
  done
  [ "$skip" -eq 1 ] && continue

  if printf '%s' "$CSP" | grep -qF "$origin"; then
    note_ok "CSP allows subresource origin: $origin"
  else
    note_fail "origin $origin appears in published HTML but is not in the CSP (allow it, or classify it as navigation-only in NON_SUBRESOURCE_ORIGINS with a reason)"
  fi
done <<< "$origins"

# The waitlist form posts to the backend via fetch(); losing that from
# connect-src would break signups silently, so pin it explicitly.
if printf '%s' "$CSP" | grep -qE "connect-src[^;]*savvy-backend"; then
  note_ok "CSP connect-src covers the signup API"
else
  note_fail "CSP connect-src does not cover the signup API — the waitlist form would break"
fi

# Inline <style>/<script> are pervasive in this site; if the CSP ever drops
# 'unsafe-inline' without a build step adding nonces, every page goes blank.
for pair in "script-src" "style-src"; do
  if printf '%s' "$CSP" | grep -qE "$pair[^;]*'unsafe-inline'"; then
    note_ok "CSP $pair keeps 'unsafe-inline' (site ships all CSS/JS inline)"
  else
    note_fail "CSP $pair drops 'unsafe-inline' but the site still has inline CSS/JS"
  fi
done

exit "$fail"
