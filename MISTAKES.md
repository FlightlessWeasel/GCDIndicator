# Mistakes

## Copilot review merge gate (2026-08-15)

**What happened:** A draft-state merge gate was added after branch protection
was found unavailable, but the workflow's `GITHUB_TOKEN` could not execute the
required GraphQL mutation and returned "Resource not accessible by
integration."

**Root cause:** The repository's GitHub Free plan does not expose branch
protection for this private repository, and the Actions integration token is
not permitted to change pull request draft state.

**Prevention:** Verify both product-plan availability and token permissions
before implementing a merge gate. Use required status checks with branch
protection when available, or explicitly configure an appropriately scoped
credential before relying on draft-state automation.
