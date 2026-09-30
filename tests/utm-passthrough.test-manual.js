// Standalone node test for buildForwardedHref — no test framework, no
// package.json in this repo. Run with: node tests/utm-passthrough.test-manual.js
// Kept out of js/ because .assetsignore publishes everything under /js/.
'use strict';

var buildForwardedHref = require('../js/utm-passthrough.js').buildForwardedHref;

var cases = [
    {
        name: 'adds a param to a bare app.withsavvy.ai href',
        run: function () {
            return buildForwardedHref('https://app.withsavvy.ai/', { utm_source: 'test' });
        },
        check: function (result) {
            return result.indexOf('utm_source=test') !== -1;
        }
    },
    {
        name: 'keeps an existing query param alongside the new one',
        run: function () {
            return buildForwardedHref('https://app.withsavvy.ai/?ref=abc', { utm_source: 'test' });
        },
        check: function (result) {
            return result.indexOf('ref=abc') !== -1 && result.indexOf('utm_source=test') !== -1;
        }
    },
    {
        name: 'overwrites an existing key instead of duplicating it',
        run: function () {
            return buildForwardedHref('https://app.withsavvy.ai/?utm_source=old', { utm_source: 'new' });
        },
        check: function (result) {
            var matches = result.match(/utm_source=/g) || [];
            return matches.length === 1 && result.indexOf('utm_source=new') !== -1;
        }
    },
    {
        name: 'preserves a #fragment',
        run: function () {
            return buildForwardedHref('https://app.withsavvy.ai/#pricing', { utm_source: 'test' });
        },
        check: function (result) {
            return result.indexOf('#pricing') === result.length - '#pricing'.length;
        }
    },
    {
        name: 'leaves a relative href and an unrelated host unchanged',
        run: function () {
            var relative = buildForwardedHref('privacy.html', { utm_source: 'test' });
            var unrelated = buildForwardedHref('https://fonts.googleapis.com/css', { utm_source: 'test' });
            return { relative: relative, unrelated: unrelated };
        },
        check: function (result) {
            return result.relative === 'privacy.html' && result.unrelated === 'https://fonts.googleapis.com/css';
        }
    },
    {
        name: 'rejects a lookalike host that merely starts with the app origin string',
        run: function () {
            return buildForwardedHref('https://app.withsavvy.ai.evil.com/', { utm_source: 'test' });
        },
        check: function (result) {
            return result === 'https://app.withsavvy.ai.evil.com/';
        }
    }
];

var failures = 0;
cases.forEach(function (testCase) {
    var result = testCase.run();
    var passed = testCase.check(result);
    console.log((passed ? 'PASS' : 'FAIL') + ' - ' + testCase.name + (passed ? '' : ' (got: ' + JSON.stringify(result) + ')'));
    if (!passed) {
        failures++;
    }
});

if (failures > 0) {
    console.log(failures + ' of ' + cases.length + ' tests failed.');
    process.exit(1);
}

console.log('All ' + cases.length + ' tests passed.');
