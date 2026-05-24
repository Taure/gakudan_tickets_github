# Architecture

`gakudan_tickets_github` is a thin adapter between two contracts:

- The `gakudan_tickets` behaviour (the normalised ticket-source API)
- GitHub's REST API for Issues (v2022-11-28)

## What lives where

| Module / function | Job |
| --- | --- |
| `gakudan_tickets_github` callbacks (`fetch/2`, `search/2`, `post_comment/3`, `apply_labels/3`, `transition/3`) | Implement the behaviour against the REST API. Translate platform errors into `{error, _}` tuples. |
| `gakudan_tickets_github:parse_issue/1` | Map a GitHub Issue JSON object into the normalised `gakudan_tickets:ticket()` shape. Exported for testing and for reuse from webhook parsing. |
| `gakudan_tickets_github:parse_webhook/2` | Decode a webhook payload + action into `{Event, Ticket}`. |
| `gakudan_tickets_github:verify_signature/3` | HMAC-SHA256 verification of `X-Hub-Signature-256`. |
| `gakudan_tickets_github:build_search_url/2` | Compose the scoped search URL. Exported to make the scoping behaviour testable. |

## Search scoping

`search/2` takes a GitHub search-syntax binary. The adapter automatically
prepends `repo:<owner>/<repo>` to the query, so a caller that knows it
only cares about the configured repo can pass `~"is:open label:bug"` and
not worry about cross-repo leakage.

## Transition mapping

`transition/3` only supports `closed` and `open` atoms in v0.1, since
GitHub Issues only model those two states. Any other atom returns
`{error, {unsupported_state, State}}`. Adapters for systems with richer
state machines (Jira workflow transitions, Linear states) will accept a
larger atom set.

## Webhook handling

The adapter is HTTP-server-agnostic: your application listens on whatever
listener it likes (Cowboy, Nova, raw Plug), reads the request body and
the `X-Hub-Signature-256` header, then calls `verify_signature/3` and
`parse_webhook/2`. The library never opens a port of its own.

## What this library is not

- Not a GitHub App framework. PAT auth only in v0.1. GitHub App + installation
  tokens are planned but not required for the common single-repo case.
- Not a polling client. Use webhooks or call `fetch/2` / `search/2`
  explicitly.
- Not a rate-limit shield. Honest about it: a heavy caller should wrap
  the adapter with their own backoff. The REST API's rate-limit headers
  are visible in the `{error, {http_error, 429, _}}` body.
