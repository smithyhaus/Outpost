# Caddy fragment examples

Reference material for application authors writing an `outpost.app.yaml` for
their repo. These fragments are **not loaded** by the running infras instance;
they document patterns that real apps have run into.

| Fragment           | Pattern demonstrated |
|--------------------|------------------------------------------------------|
| `scm-mcp.caddy`    | One host, multiple upstreams with disagreeing trailing-slash conventions; dashboard split via path matchers; legacy alias for 30-day deprecation window. |

> **Why this lives in the infras repo, not in the app's repo:** apps onboard
> *into* an infras instance — keeping a known-good set of route patterns
> alongside infras lets app authors copy a starting point without first
> tracking down a sample. The pattern stays here; the **live route** for
> any specific app lives in that app's repo (`outpost/app.caddy`) and is
> rendered into `core/compose/Caddyfile.d/` by `outpost onboard`.
