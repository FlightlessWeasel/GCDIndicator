# Mistakes

## Copilot review merge gate (2026-08-15)

**What happened:** The initial draft-gate workflow used
`github.rest.pulls.convertToDraft` and
`github.rest.pulls.markReadyForReview`, which are unavailable in
`actions/github-script@v7`. A follow-up incorrectly assumed equivalent REST
endpoints existed.

**Root cause:** The helper names and REST endpoints were inferred from examples
without verifying that GitHub exposes these draft-state mutations through its
GraphQL API only.

**Prevention:** Verify the API surface before implementation. Use
`github.graphql()` with the documented
`convertPullRequestToDraft`/`markPullRequestReadyForReview` mutations for
draft-state changes.
