-module(gakudan_tickets_github_app).
-moduledoc false.

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    gakudan_tickets_github_sup:start_link().

stop(_State) ->
    ok.
