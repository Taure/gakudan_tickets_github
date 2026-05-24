# gakudan_tickets_github

[![CI](https://github.com/Taure/gakudan_tickets_github/actions/workflows/ci.yml/badge.svg)](https://github.com/Taure/gakudan_tickets_github/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Taure/gakudan_tickets_github)](LICENSE)
[![Erlang](https://img.shields.io/badge/erlang-28%2B-blue)](.tool-versions)

GitHub Issues adapter for [gakudan_tickets](https://github.com/Taure/gakudan_tickets).

Implements the `gakudan_tickets` behaviour against GitHub's REST API
(v2022-11-28). Lets gakudan triage agents read + write issues, comments,
labels, and state transitions on a single repo via the normalised
ticket-source contract.

## Quickstart

```erlang
%% Build a source_ref for one repo
Ref = gakudan_tickets_github:source(#{
    owner => ~"Taure",
    repo  => ~"gakudan",
    token => list_to_binary(os:getenv("GITHUB_TOKEN"))
}).

%% Fetch one issue
{ok, Ticket} = gakudan_tickets_github:fetch(Ref, ~"42").

%% Or via the gakudan_tickets dispatch helper (parametrised on the adapter)
{ok, Ticket} = gakudan_tickets:fetch(gakudan_tickets_github, Ref, ~"42").

%% Post a triage comment
ok = gakudan_tickets_github:post_comment(Ref, ~"42", ~"thanks for the report").

%% Apply labels (replaces the existing label set)
ok = gakudan_tickets_github:apply_labels(Ref, ~"42", [~"bug", ~"triaged"]).
```

## Webhooks

The library is HTTP-server-agnostic. Listen on your own endpoint, verify
the signature, and parse the body:

```erlang
%% inside your cowboy / nova / plug handler:
{ok, Body, Req1} = cowboy_req:read_body(Req),
Sig  = cowboy_req:header(~"x-hub-signature-256", Req1),
true = gakudan_tickets_github:verify_signature(WebhookSecret, Sig, Body),
EventType = cowboy_req:header(~"x-github-event", Req1),
case gakudan_tickets_github:parse_webhook(EventType, Body) of
    {ok, {issue_opened, Ticket}}  -> spawn_triage(Ticket);
    {ok, {issue_labeled, Ticket}} -> maybe_dispatch(Ticket);
    {ok, {Event, _Ticket}}        -> ignore(Event);
    {error, _}                    -> bad_request
end.
```

`verify_signature/3` uses `crypto:hash_equals/2` for constant-time
comparison. `parse_webhook/2` handles the `issues` event type in v0.1
(other types return `{error, {unsupported_event, _}}`).

## Search

```erlang
%% Scoped automatically to the configured repo
{ok, Tickets} = gakudan_tickets_github:search(Ref, ~"is:open label:bug").
```

The adapter prepends `repo:<owner>/<repo>` to whatever search query you
pass. Standard [GitHub issue search syntax](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).

## Transitions

```erlang
ok = gakudan_tickets_github:transition(Ref, ~"42", closed).
ok = gakudan_tickets_github:transition(Ref, ~"42", open).
```

Only `closed` and `open` are supported (the only states GitHub Issues
model). Any other atom returns `{error, {unsupported_state, _}}`.

## Auth

Personal Access Token only in v0.1. GitHub App + installation tokens are
a planned addition.

The token needs `issues:write` to apply labels / post comments / transition.

## What it normalises into

Every API call that returns issue data is mapped into the standard
[`gakudan_tickets:ticket()`](https://github.com/Taure/gakudan_tickets/blob/main/src/gakudan_tickets.erl)
shape:

```erlang
#{
    id := binary(),            %% the issue number, stringified
    title := binary(),
    body := binary(),          %% null bodies normalised to ~""
    author := binary(),
    labels := [binary()],
    created_at := integer(),   %% system_time in seconds
    source := github,
    raw := map()               %% the full GitHub Issue JSON, escape hatch
}
```

## License

MIT.
