// Progressive enhancement for footer "Contact" links.
//
// A bare `mailto:` href silently does nothing on a machine with no
// registered mail handler (reported by a user-test: Chrome on an old Intel
// Mac, macOS 15.7.7 — clicking "Contact" opened nothing). This script never
// prevents the default mailto navigation — it only adds a clipboard-copy
// fallback alongside it, so the address is still usable when nothing opens.
//
// Applies to every element carrying [data-contact-email] across the site.
(function () {
    var COPIED_DURATION_MS = 2500;

    function bindContactLink(link) {
        if (link.getAttribute('data-contact-link-bound') === 'true') {
            return;
        }
        link.setAttribute('data-contact-link-bound', 'true');

        var originalText = link.textContent;
        var restoreTimer = null;

        link.addEventListener('click', function () {
            var email = link.getAttribute('data-contact-email');
            if (!email) {
                return;
            }
            if (!navigator.clipboard || !navigator.clipboard.writeText) {
                return;
            }

            navigator.clipboard.writeText(email).then(function () {
                if (restoreTimer) {
                    clearTimeout(restoreTimer);
                }
                link.textContent = 'Copied ' + email + ' ✓';
                restoreTimer = setTimeout(function () {
                    link.textContent = originalText;
                    restoreTimer = null;
                }, COPIED_DURATION_MS);
            }, function () {
                // Clipboard write rejected (permissions, insecure context,
                // etc.) — leave the link text untouched. The mailto: href
                // was never prevented, so it still had its normal chance
                // to open a mail client.
            });
        });
    }

    document.addEventListener('DOMContentLoaded', function () {
        var links = document.querySelectorAll('[data-contact-email]');
        for (var i = 0; i < links.length; i++) {
            bindContactLink(links[i]);
        }
    });
})();
