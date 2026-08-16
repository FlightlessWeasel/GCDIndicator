# Mistakes

## Copilot review merge gate (2026-08-15)

**What happened:** The initial draft-gate workflow used
`github.rest.pulls.convertToDraft` and
`github.rest.pulls.markReadyForReview`, but those generated helpers are not
available in `actions/github-script@v7`.

**Root cause:** The helper names were inferred from examples without verifying
the action's installed Octokit REST surface.

**Prevention:** Use `github.request()` with the documented REST endpoint when
an action's generated REST helper has not been verified in that action version.
