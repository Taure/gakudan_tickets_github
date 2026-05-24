-module(gakudan_tickets_github).
-moduledoc """
GitHub Issues adapter for [gakudan_tickets](https://github.com/Taure/gakudan_tickets).

Implements the `gakudan_tickets` behaviour against GitHub's REST API
(v2022-11-28). Reads + writes a single repo at a time.

## Auth

Two modes are supported:

### Personal Access Token

```erlang
Ref = gakudan_tickets_github:source(#{
    owner => ~"Taure",
    repo  => ~"gakudan",
    token => list_to_binary(os:getenv("GITHUB_TOKEN"))
}).
```

Simplest setup. Posts appear as the user who minted the PAT. Fine for
single-maintainer dog-fooding.

### GitHub App

```erlang
Ref = gakudan_tickets_github:source(#{
    owner => ~"Taure",
    repo  => ~"gakudan",
    app   => #{
        app_id          => 123456,
        private_key_pem => read_pem("triagebot.pem"),
        installation_id => 7891011
    }
}).
```

Posts appear as the App's bot account (`@<app-name>[bot]`). Installation
tokens are fetched on first use and cached until shortly before expiry
(5-minute refresh buffer) by the `gakudan_tickets_github_token_cache`
gen_server, which is started automatically when the OTP application starts.

Add `gakudan_tickets_github` to your application's `applications` list so
the cache is up and ready when you start making calls.

## Webhooks

A consuming application listens on its own HTTP endpoint, verifies the
signature with `verify_signature/3`, and parses the body with
`parse_webhook/2`:

```erlang
Body = read_request_body(...),
Sig  = header(~"x-hub-signature-256", ...),
true = gakudan_tickets_github:verify_signature(Secret, Sig, Body),
{ok, {issue_opened, Ticket}} =
    gakudan_tickets_github:parse_webhook(~"issues", Body).
```

`Ticket` is the normalised `gakudan_tickets:ticket()` shape, ready to
hand to a gakudan triage run.

## Search

`search/2` accepts a GitHub search-syntax binary. The adapter scopes the
query to the configured owner/repo automatically, so a caller passing
`~"is:open label:bug"` searches only that repo.
""".

-behaviour(gakudan_tickets).

-export([fetch/2, search/2, post_comment/3, apply_labels/3, transition/3]).
-export([source/1, get_file/2, get_file/3, list_labels/1]).
-export([
    parse_issue/1,
    parse_webhook/2,
    verify_signature/3,
    build_search_url/2,
    parse_file_contents/1,
    parse_labels_response/1
]).

-define(DEFAULT_BASE_URL, ~"https://api.github.com").
-define(DEFAULT_TIMEOUT, 30_000).
-define(API_VERSION, "2022-11-28").

%% --- public ---

-doc """
Build a `source_ref()` for one repository.

Accepts either Personal Access Token auth (`token`) or GitHub App auth
(`app`) - see the module docs for the shapes.
""".
-spec source(map()) -> gakudan_tickets:source_ref().
source(#{owner := O, repo := R, app := App} = Opts) when is_map(App) ->
    #{
        owner => O,
        repo => R,
        app => App,
        base_url => maps:get(base_url, Opts, ?DEFAULT_BASE_URL)
    };
source(#{owner := O, repo := R, token := T} = Opts) ->
    #{
        owner => O,
        repo => R,
        token => T,
        base_url => maps:get(base_url, Opts, ?DEFAULT_BASE_URL)
    }.

%% --- behaviour callbacks ---

fetch(#{owner := O, repo := R} = Ref, Id) when is_binary(Id) ->
    Url = url(Ref, ["/repos/", O, "/", R, "/issues/", Id]),
    case http(get, Url, Ref, undefined) of
        {ok, Json} -> {ok, parse_issue(Json)};
        Err -> Err
    end.

search(Ref, Query) when is_binary(Query) ->
    Url = build_search_url(Ref, Query),
    case http(get, Url, Ref, undefined) of
        {ok, Decoded} ->
            Items = maps:get(~"items", Decoded, []),
            {ok, [parse_issue(I) || I <- Items]};
        Err ->
            Err
    end.

post_comment(#{owner := O, repo := R} = Ref, Id, Body) when is_binary(Id), is_binary(Body) ->
    Url = url(Ref, ["/repos/", O, "/", R, "/issues/", Id, "/comments"]),
    Payload = iolist_to_binary(json:encode(#{body => Body})),
    case http(post, Url, Ref, Payload) of
        {ok, _} -> ok;
        Err -> Err
    end.

apply_labels(#{owner := O, repo := R} = Ref, Id, Labels) when is_binary(Id), is_list(Labels) ->
    Url = url(Ref, ["/repos/", O, "/", R, "/issues/", Id, "/labels"]),
    Payload = iolist_to_binary(json:encode(#{labels => Labels})),
    case http(put, Url, Ref, Payload) of
        {ok, _} -> ok;
        Err -> Err
    end.

transition(#{owner := O, repo := R} = Ref, Id, State) when
    is_binary(Id), (State =:= closed orelse State =:= open)
->
    Url = url(Ref, ["/repos/", O, "/", R, "/issues/", Id]),
    Payload = iolist_to_binary(json:encode(#{state => atom_to_binary(State)})),
    case http(patch, Url, Ref, Payload) of
        {ok, _} -> ok;
        Err -> Err
    end;
transition(_, _, State) ->
    {error, {unsupported_state, State}}.

%% --- extra reads (not part of the gakudan_tickets behaviour) ---

-doc """
Fetch a file from the repo's default branch.

Returns the raw file contents as a binary. For files larger than
GitHub's inline-content limit (~1 MB) returns `{error, too_large}`;
the caller can fall back to the `download_url` from the raw JSON. For
directories returns `{error, is_directory}`.
""".
-spec get_file(map(), binary() | string()) -> {ok, binary()} | {error, term()}.
get_file(Ref, Path) ->
    get_file(Ref, Path, undefined).

-doc """
Fetch a file at a specific git ref (branch, tag, or commit SHA).

Pass `undefined` for `Ref` to use the repo's default branch.
""".
-spec get_file(map(), binary() | string(), binary() | string() | undefined) ->
    {ok, binary()} | {error, term()}.
get_file(#{owner := O, repo := R} = Ref, Path, GitRef) when
    is_binary(Path) orelse is_list(Path)
->
    Url0 = url(Ref, ["/repos/", O, "/", R, "/contents/", Path]),
    Url =
        case GitRef of
            undefined -> Url0;
            _ -> Url0 ++ "?ref=" ++ to_str(GitRef)
        end,
    case http(get, Url, Ref, undefined) of
        {ok, Json} -> parse_file_contents(Json);
        {error, {http_error, 404, _}} -> {error, not_found};
        Err -> Err
    end.

-doc """
List all labels defined on the repo.

Returns the labels as a list of `#{name, description, color}` maps.
Pagination is **not** followed in v0.1 — the first page (up to 100
labels, GitHub's per_page max) is returned.
""".
-spec list_labels(map()) ->
    {ok, [#{name := binary(), description := binary(), color := binary()}]}
    | {error, term()}.
list_labels(#{owner := O, repo := R} = Ref) ->
    Url = url(Ref, ["/repos/", O, "/", R, "/labels?per_page=100"]),
    case http(get, Url, Ref, undefined) of
        {ok, Labels} when is_list(Labels) -> {ok, parse_labels_response(Labels)};
        {error, _} = Err -> Err;
        Other -> {error, {unexpected_response, Other}}
    end.

%% --- pure helpers (exported for testing) ---

-doc """
Decode a GitHub "Get repository content" JSON response into the raw
file bytes. Used internally by `get_file/2,3` and exposed for tests.
""".
-spec parse_file_contents(map() | list()) -> {ok, binary()} | {error, term()}.
parse_file_contents(L) when is_list(L) ->
    {error, is_directory};
parse_file_contents(#{~"type" := ~"dir"}) ->
    {error, is_directory};
parse_file_contents(#{~"encoding" := ~"base64", ~"content" := Encoded}) when is_binary(Encoded) ->
    Stripped = binary:replace(Encoded, ~"\n", ~"", [global]),
    try
        {ok, base64:decode(Stripped)}
    catch
        _:Reason -> {error, {bad_base64, Reason}}
    end;
parse_file_contents(#{~"encoding" := ~"none"}) ->
    {error, too_large};
parse_file_contents(_) ->
    {error, unexpected_shape}.

-doc """
Normalise a "List repository labels" response into a list of
`#{name, description, color}` maps. Used internally by `list_labels/1`
and exposed for tests.
""".
-spec parse_labels_response([map()]) ->
    [#{name := binary(), description := binary(), color := binary()}].
parse_labels_response(Labels) ->
    [
        #{
            name => default_binary(maps:get(~"name", L, ~"")),
            description => default_binary(maps:get(~"description", L, ~"")),
            color => default_binary(maps:get(~"color", L, ~""))
        }
     || L <- Labels
    ].

-doc "Normalise a GitHub Issue JSON object into a gakudan_tickets:ticket().".
-spec parse_issue(map()) -> gakudan_tickets:ticket().
parse_issue(Issue) ->
    #{
        id => integer_to_binary(maps:get(~"number", Issue, 0)),
        title => default_binary(maps:get(~"title", Issue, ~"")),
        body => default_binary(maps:get(~"body", Issue, ~"")),
        author => default_binary(
            maps:get(~"login", maps:get(~"user", Issue, #{}), ~"")
        ),
        labels => parse_labels(maps:get(~"labels", Issue, [])),
        created_at => parse_timestamp(maps:get(~"created_at", Issue, ~"")),
        source => github,
        raw => Issue
    }.

-doc """
Parse a webhook event into a `{Event, Ticket}` pair.

`EventType` is the value of the `X-GitHub-Event` header. v0.1 handles
the `issues` event type; other types return `{error, {unsupported_event, Type}}`.
""".
-spec parse_webhook(binary(), binary()) ->
    {ok, {
        issue_opened
        | issue_labeled
        | issue_closed
        | issue_reopened
        | issue_edited
        | {issue, atom()},
        gakudan_tickets:ticket()
    }}
    | {error, term()}.
parse_webhook(~"issues", Body) when is_binary(Body) ->
    try json:decode(Body) of
        Decoded ->
            Action = maps:get(~"action", Decoded, ~"unknown"),
            Issue = maps:get(~"issue", Decoded, #{}),
            Ticket = parse_issue(Issue),
            {ok, {action_to_event(Action), Ticket}}
    catch
        _:Reason -> {error, {bad_json, Reason}}
    end;
parse_webhook(Type, _Body) ->
    {error, {unsupported_event, Type}}.

action_to_event(~"opened") -> issue_opened;
action_to_event(~"labeled") -> issue_labeled;
action_to_event(~"closed") -> issue_closed;
action_to_event(~"reopened") -> issue_reopened;
action_to_event(~"edited") -> issue_edited;
action_to_event(Other) -> {issue, binary_to_atom(Other)}.

-doc """
Verify a GitHub webhook signature against the shared secret.

`Signature` is the value of the `X-Hub-Signature-256` header
(`"sha256=<hex>"`). `Body` is the raw request body bytes.
Constant-time comparison via `crypto:hash_equals/2`.
""".
-spec verify_signature(binary(), binary(), binary()) -> boolean().
verify_signature(Secret, <<"sha256=", Provided/binary>>, Body) when
    is_binary(Secret), is_binary(Body)
->
    Expected = sha256_hex(Secret, Body),
    crypto:hash_equals(Provided, Expected);
verify_signature(_, _, _) ->
    false.

-doc "Build the search-issues URL with the query scoped to the configured repo.".
-spec build_search_url(map(), binary()) -> string().
build_search_url(#{base_url := Base, owner := O, repo := R}, Query) ->
    Scoped = iolist_to_binary([~"repo:", O, ~"/", R, ~" ", Query]),
    QueryStr = uri_string:compose_query([{~"q", Scoped}]),
    binary_to_list(iolist_to_binary([Base, ~"/search/issues?", QueryStr])).

%% --- internal ---

sha256_hex(Secret, Body) ->
    Hash = crypto:mac(hmac, sha256, Secret, Body),
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash]).

parse_labels(Labels) ->
    [default_binary(maps:get(~"name", L, ~"")) || L <- Labels].

default_binary(null) -> ~"";
default_binary(B) when is_binary(B) -> B;
default_binary(_) -> ~"".

parse_timestamp(<<>>) ->
    0;
parse_timestamp(B) when is_binary(B) ->
    try calendar:rfc3339_to_system_time(binary_to_list(B)) of
        N when is_integer(N) -> N
    catch
        _:_ -> 0
    end.

url(#{base_url := Base}, Parts) ->
    binary_to_list(iolist_to_binary([Base | [to_bin(P) || P <- Parts]])).

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(L) when is_list(L) -> iolist_to_binary(L).

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(L) when is_list(L) -> L.

http(Method, Url, Ref, Body) ->
    case resolve_token(Ref) of
        {ok, Token} -> do_http(Method, Url, Token, Body);
        {error, _} = Err -> Err
    end.

resolve_token(#{token := T}) ->
    {ok, T};
resolve_token(#{app := App}) ->
    gakudan_tickets_github_token_cache:get_token(App);
resolve_token(_) ->
    {error, no_auth}.

do_http(Method, Url, Token, Body) ->
    ok = ensure_inets(),
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(Token)},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", ?API_VERSION},
        {"user-agent", "gakudan_tickets_github"}
    ],
    Request =
        case Body of
            undefined -> {Url, Headers};
            _ -> {Url, Headers, "application/json", Body}
        end,
    Result = httpc:request(Method, Request, [{timeout, ?DEFAULT_TIMEOUT}], [
        {body_format, binary}
    ]),
    case Result of
        {ok, {{_, Code, _}, _RespHdrs, RespBody}} when Code >= 200, Code < 300 ->
            decode_response(RespBody);
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http_error, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

decode_response(<<>>) ->
    {ok, #{}};
decode_response(Body) ->
    try
        {ok, json:decode(Body)}
    catch
        _:Reason -> {error, {bad_json, Reason}}
    end.

ensure_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    case ssl:start() of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end.
