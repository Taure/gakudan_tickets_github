-module(gakudan_tickets_github_token_cache).
-moduledoc """
gen_server that caches GitHub App installation tokens, refreshing them
as they approach expiry.

Installation tokens are valid for 1 hour. This cache returns the same
token until it has less than `?REFRESH_BUFFER` seconds remaining, at
which point it fetches a new one from the GitHub API.

Cached entries are keyed by `{AppId, InstallationId}` so a single
process can hold tokens for multiple installations (multi-tenant use
case).
""".

-behaviour(gen_server).

-export([start_link/0, get_token/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(REFRESH_BUFFER, 300).
-define(FETCH_TIMEOUT, 15000).

%% --- public ---

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_token(map()) -> {ok, binary()} | {error, term()}.
get_token(AppCfg) when is_map(AppCfg) ->
    gen_server:call(?MODULE, {get_token, AppCfg}, 30000).

%% --- gen_server ---

init([]) ->
    {ok, #{}}.

handle_call({get_token, AppCfg}, _From, State) ->
    Key = {maps:get(app_id, AppCfg), maps:get(installation_id, AppCfg)},
    Now = erlang:system_time(second),
    case maps:get(Key, State, undefined) of
        {Token, ExpAt} when ExpAt > Now + ?REFRESH_BUFFER ->
            {reply, {ok, Token}, State};
        _ ->
            case fetch_token(AppCfg) of
                {ok, Token, ExpAt} ->
                    {reply, {ok, Token}, State#{Key => {Token, ExpAt}}};
                {error, _} = Err ->
                    {reply, Err, State}
            end
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% --- internal ---

fetch_token(#{app_id := AppId, private_key_pem := Pem, installation_id := InstId} = AppCfg) ->
    Now = erlang:system_time(second),
    Jwt = gakudan_tickets_github_jwt:build(AppId, Pem, Now),
    BaseUrl = maps:get(base_url, AppCfg, ~"https://api.github.com"),
    Url = binary_to_list(
        iolist_to_binary([
            BaseUrl,
            ~"/app/installations/",
            integer_to_binary(InstId),
            ~"/access_tokens"
        ])
    ),
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(Jwt)},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "gakudan_tickets_github"}
    ],
    ok = ensure_inets(),
    Request = {Url, Headers, "application/json", <<>>},
    case httpc:request(post, Request, [{timeout, ?FETCH_TIMEOUT}], [{body_format, binary}]) of
        {ok, {{_, 201, _}, _, Body}} ->
            parse_response(Body);
        {ok, {{_, Code, _}, _, Body}} ->
            {error, {http_error, Code, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

parse_response(Body) ->
    try
        Decoded = json:decode(Body),
        Token = maps:get(~"token", Decoded),
        ExpStr = maps:get(~"expires_at", Decoded),
        ExpAt = calendar:rfc3339_to_system_time(binary_to_list(ExpStr)),
        {ok, Token, ExpAt}
    catch
        _:Reason -> {error, {bad_token_response, Reason}}
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
