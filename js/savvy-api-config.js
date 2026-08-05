// Single source of truth for the Savvy backend API origin used by static
// pages in this repo (waitlist forms, admin dashboard).
//
// Production traffic goes through the canonical API domain (api.withsavvy.ai),
// which fronts the `savvy-backend` Render service — never the raw
// `*.onrender.com` hostname, which is not guaranteed stable and bypasses
// whatever is layered in front of the canonical domain (CDN, WAF, etc.).
(function (global) {
    var isLocal = global.location.hostname === 'localhost' || global.location.hostname === '127.0.0.1';
    global.SAVVY_API_ORIGIN = isLocal ? 'http://localhost:3000' : 'https://api.withsavvy.ai';
})(window);
