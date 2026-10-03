#!/usr/bin/env bash
# ci_surface_paths.sh — the ONE definition of "CI-surface" paths for this repo.
#
# [2026-10-02, savvy-backend#1595 / tracking #1239 — review fix, ported to savvy_landing]
# gate.yml's review/opus-gate floors matched `^[.]github/(workflows|scripts)/`
# while merge-guard.yml matched that PLUS `^[.]claude/scripts/`, so a
# `.claude/scripts/` change passed gate.yml's FLOOR (and could post
# `opus-verdict-recorded=success` on an Opus PASS) while merge-guard failed it.
# Neither covered `.github/CODEOWNERS` or `.github/dependabot.yml`, which
# auto-arm-merge.yml's arm-or-hold already treats as brick-risk (and which are
# the files that decide WHO must review the workflows).
#
# Sourced by: gate.yml (review + opus-gate floors) and
# post_opus_verdict_recorded.sh (dependabot CI-surface check).
# merge-guard.yml has no checkout (and must not grow one: it is a label-only
# check on the hosted pool), so it carries the SAME literal inline;
# __tests__/ci_surface_paths.test.sh asserts the two are byte-identical.
# Edit BOTH or that test fails.
#
# Usage:  . .github/scripts/ci_surface_paths.sh
#         printf '%s\n' "$FILES" | grep -Eq "$CI_SURFACE_REGEX"
# shellcheck disable=SC2034  # consumed by the sourcing script
CI_SURFACE_REGEX='^[.]github/(workflows|scripts)/|^[.]claude/scripts/|^[.]github/(CODEOWNERS|dependabot[.]yml)$'
