-module(gakudan_tickets_github_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => gakudan_tickets_github_token_cache,
            start => {gakudan_tickets_github_token_cache, start_link, []},
            type => worker,
            restart => permanent,
            shutdown => 5000
        }
    ],
    {ok, {SupFlags, Children}}.
