// Forwards UTM params from this page's URL onto every app.withsavvy.ai link
// and the hero audit form, so they survive the cross-origin click-through
// (sessionStorage written here never reaches app.withsavvy.ai).
// On index.html the hero form's submit handler and the card-pick CTAs build
// their URLs in appUrl(), which forwards the same keys itself: that handler
// never reads the hidden inputs added below, and syncCtas() overwrites the
// follow-link hrefs this script sets.
(function () {
    'use strict';

    var APP_ORIGIN = 'https://app.withsavvy.ai';
    var UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content'];

    function buildForwardedHref(href, params) {
        if (typeof href !== 'string' || href.indexOf(APP_ORIGIN) !== 0) {
            return href;
        }
        var url;
        try {
            url = new URL(href);
        } catch (e) {
            return href;
        }
        // Exact-origin check (not just prefix) so a lookalike host like
        // "https://app.withsavvy.ai.evil.com" is never rewritten.
        if (url.origin !== APP_ORIGIN) {
            return href;
        }
        Object.keys(params).forEach(function (key) {
            url.searchParams.set(key, params[key]);
        });
        return url.toString();
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { buildForwardedHref: buildForwardedHref };
    }

    if (typeof document === 'undefined' || typeof window === 'undefined') {
        return;
    }

    document.addEventListener('DOMContentLoaded', function () {
        var searchParams = new URLSearchParams(window.location.search);
        var params = {};
        UTM_KEYS.forEach(function (key) {
            if (searchParams.has(key)) {
                params[key] = searchParams.get(key);
            }
        });

        if (Object.keys(params).length === 0) {
            return;
        }

        var anchors = document.querySelectorAll('a[href^="' + APP_ORIGIN + '"]');
        anchors.forEach(function (anchor) {
            var forwarded = buildForwardedHref(anchor.href, params);
            if (forwarded !== anchor.href) {
                anchor.href = forwarded;
            }
        });

        var form = document.querySelector('.hero-audit-form');
        if (!form) {
            return;
        }
        Object.keys(params).forEach(function (key) {
            var existing = form.querySelector('input[name="' + key + '"]');
            if (existing) {
                existing.value = params[key];
                return;
            }
            var input = document.createElement('input');
            input.type = 'hidden';
            input.name = key;
            input.value = params[key];
            form.appendChild(input);
        });
    });
}());
