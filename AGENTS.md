# AGENTS.md

Working agreement for agents and contributors on **gakudan_tickets_github** -
the GitHub Issues adapter for gakudan_tickets.

## Ecosystem

A gakudan sister library in a BEAM-native multi-agent stack (all under
https://github.com/Taure):

- **[gakudan](https://github.com/Taure/gakudan)** - agent orchestration runtime.
- **[saiten](https://github.com/Taure/saiten)** - runtime-agnostic eval/scoring
  + CI gate.
- **[madoguchi](https://github.com/Taure/madoguchi)** - MCP *server* framework.
- **[sekisho](https://github.com/Taure/sekisho)** - LLM gateway / control plane
  (virtual keys, budgets, audit; Anthropic + OpenAI chat + embeddings + Vertex).
- **[bunko](https://github.com/Taure/bunko)** - agent memory + RAG (pgvector).
- **[banto](https://github.com/Taure/banto)** - multi-agent repo concierge; the
  showcase consumer wiring the pillars together.

Other gakudan sisters: gakudan_metrics, gakudan_otel, gakudan_liveboard.

**This repo** implements the
**[gakudan_tickets](https://github.com/Taure/gakudan_tickets)** ticket-source
behaviour against the GitHub Issues API (webhook parsing + HMAC signature
verification).

## Conventions

- OTP 29+. The `~"..."` sigil, never `<<"...">>`. No `lists:foldl/foldr`.
- JSON via the OTP `json` module. `?LOG_*` macros with `#{...}` map reports.
- Docs: OTP `-moduledoc` / `-doc`. `{vsn, "git"}` - version derives from git tags.
- Default to zero comments; comment only non-obvious *why*.

## Commands

```bash
rebar3 compile
rebar3 eunit
rebar3 fmt          # CI runs fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc
```

## Git and PRs

Conventional commits. Always open a PR - never push to `main`. Every merge to
`main` tags a release.
