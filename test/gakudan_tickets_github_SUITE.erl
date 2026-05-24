-module(gakudan_tickets_github_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    parse_issue_normalises_minimal_payload/1,
    parse_issue_extracts_labels_and_author/1,
    parse_issue_handles_null_body/1,
    parse_issue_keeps_raw_for_escape_hatch/1,
    parse_webhook_issue_opened/1,
    parse_webhook_issue_labeled/1,
    parse_webhook_unknown_action_falls_through/1,
    parse_webhook_unsupported_event_returns_error/1,
    parse_webhook_bad_json_returns_error/1,
    verify_signature_accepts_correct_hmac/1,
    verify_signature_rejects_wrong_secret/1,
    verify_signature_rejects_missing_prefix/1,
    build_search_url_scopes_to_repo/1,
    source_carries_required_fields/1,
    source_with_app_config_carries_app_field/1,
    transition_rejects_unsupported_state/1,
    parse_file_contents_decodes_base64/1,
    parse_file_contents_strips_newlines_from_base64/1,
    parse_file_contents_rejects_directory_listing/1,
    parse_file_contents_rejects_too_large_file/1,
    parse_file_contents_rejects_unknown_shape/1,
    parse_labels_response_normalises_each_label/1,
    parse_labels_response_handles_null_description/1
]).

all() ->
    [
        parse_issue_normalises_minimal_payload,
        parse_issue_extracts_labels_and_author,
        parse_issue_handles_null_body,
        parse_issue_keeps_raw_for_escape_hatch,
        parse_webhook_issue_opened,
        parse_webhook_issue_labeled,
        parse_webhook_unknown_action_falls_through,
        parse_webhook_unsupported_event_returns_error,
        parse_webhook_bad_json_returns_error,
        verify_signature_accepts_correct_hmac,
        verify_signature_rejects_wrong_secret,
        verify_signature_rejects_missing_prefix,
        build_search_url_scopes_to_repo,
        source_carries_required_fields,
        source_with_app_config_carries_app_field,
        transition_rejects_unsupported_state,
        parse_file_contents_decodes_base64,
        parse_file_contents_strips_newlines_from_base64,
        parse_file_contents_rejects_directory_listing,
        parse_file_contents_rejects_too_large_file,
        parse_file_contents_rejects_unknown_shape,
        parse_labels_response_normalises_each_label,
        parse_labels_response_handles_null_description
    ].

%% --- parse_issue ---

parse_issue_normalises_minimal_payload(_Config) ->
    Issue = #{
        ~"number" => 42,
        ~"title" => ~"hello",
        ~"body" => ~"world",
        ~"user" => #{~"login" => ~"alice"},
        ~"labels" => [],
        ~"created_at" => ~"2026-05-23T10:00:00Z"
    },
    Ticket = gakudan_tickets_github:parse_issue(Issue),
    ?assertEqual(~"42", maps:get(id, Ticket)),
    ?assertEqual(~"hello", maps:get(title, Ticket)),
    ?assertEqual(~"world", maps:get(body, Ticket)),
    ?assertEqual(~"alice", maps:get(author, Ticket)),
    ?assertEqual([], maps:get(labels, Ticket)),
    ?assertEqual(github, maps:get(source, Ticket)),
    ?assert(maps:get(created_at, Ticket) > 0).

parse_issue_extracts_labels_and_author(_Config) ->
    Issue = #{
        ~"number" => 7,
        ~"title" => ~"bug",
        ~"body" => ~"reproducer here",
        ~"user" => #{~"login" => ~"bob"},
        ~"labels" => [
            #{~"name" => ~"bug"},
            #{~"name" => ~"triaged"}
        ],
        ~"created_at" => ~"2026-05-23T11:00:00Z"
    },
    Ticket = gakudan_tickets_github:parse_issue(Issue),
    ?assertEqual([~"bug", ~"triaged"], maps:get(labels, Ticket)),
    ?assertEqual(~"bob", maps:get(author, Ticket)).

parse_issue_handles_null_body(_Config) ->
    Issue = #{
        ~"number" => 1,
        ~"title" => ~"empty",
        ~"body" => null,
        ~"user" => #{~"login" => ~"nobody"},
        ~"labels" => [],
        ~"created_at" => ~"2026-05-23T12:00:00Z"
    },
    Ticket = gakudan_tickets_github:parse_issue(Issue),
    ?assertEqual(~"", maps:get(body, Ticket)).

parse_issue_keeps_raw_for_escape_hatch(_Config) ->
    Issue = #{
        ~"number" => 100,
        ~"title" => ~"with custom field",
        ~"body" => ~"x",
        ~"user" => #{~"login" => ~"u"},
        ~"labels" => [],
        ~"created_at" => ~"2026-05-23T13:00:00Z",
        ~"assignees" => [#{~"login" => ~"reviewer"}],
        ~"milestone" => #{~"title" => ~"v0.1"}
    },
    Ticket = gakudan_tickets_github:parse_issue(Issue),
    Raw = maps:get(raw, Ticket),
    ?assertEqual(Issue, Raw),
    ?assert(maps:is_key(~"assignees", Raw)),
    ?assert(maps:is_key(~"milestone", Raw)).

%% --- parse_webhook ---

parse_webhook_issue_opened(_Config) ->
    Payload = iolist_to_binary(
        json:encode(#{
            ~"action" => ~"opened",
            ~"issue" => #{
                ~"number" => 1,
                ~"title" => ~"new bug",
                ~"body" => ~"steps",
                ~"user" => #{~"login" => ~"reporter"},
                ~"labels" => [],
                ~"created_at" => ~"2026-05-23T10:00:00Z"
            }
        })
    ),
    {ok, {Event, Ticket}} = gakudan_tickets_github:parse_webhook(~"issues", Payload),
    ?assertEqual(issue_opened, Event),
    ?assertEqual(~"1", maps:get(id, Ticket)),
    ?assertEqual(~"new bug", maps:get(title, Ticket)).

parse_webhook_issue_labeled(_Config) ->
    Payload = iolist_to_binary(
        json:encode(#{
            ~"action" => ~"labeled",
            ~"issue" => #{
                ~"number" => 2,
                ~"title" => ~"x",
                ~"body" => ~"y",
                ~"user" => #{~"login" => ~"u"},
                ~"labels" => [#{~"name" => ~"claude-try"}],
                ~"created_at" => ~"2026-05-23T10:00:00Z"
            }
        })
    ),
    {ok, {Event, Ticket}} = gakudan_tickets_github:parse_webhook(~"issues", Payload),
    ?assertEqual(issue_labeled, Event),
    ?assertEqual([~"claude-try"], maps:get(labels, Ticket)).

parse_webhook_unknown_action_falls_through(_Config) ->
    Payload = iolist_to_binary(
        json:encode(#{
            ~"action" => ~"transferred",
            ~"issue" => #{
                ~"number" => 3,
                ~"title" => ~"x",
                ~"body" => ~"y",
                ~"user" => #{~"login" => ~"u"},
                ~"labels" => [],
                ~"created_at" => ~"2026-05-23T10:00:00Z"
            }
        })
    ),
    {ok, {Event, _Ticket}} = gakudan_tickets_github:parse_webhook(~"issues", Payload),
    ?assertEqual({issue, transferred}, Event).

parse_webhook_unsupported_event_returns_error(_Config) ->
    {error, {unsupported_event, ~"pull_request"}} =
        gakudan_tickets_github:parse_webhook(~"pull_request", ~"{}").

parse_webhook_bad_json_returns_error(_Config) ->
    {error, {bad_json, _}} =
        gakudan_tickets_github:parse_webhook(~"issues", ~"not json{").

%% --- verify_signature ---

verify_signature_accepts_correct_hmac(_Config) ->
    Secret = ~"my-webhook-secret",
    Body = ~"{\"action\":\"opened\"}",
    Hex = hmac_sha256_hex(Secret, Body),
    Header = <<"sha256=", Hex/binary>>,
    ?assert(gakudan_tickets_github:verify_signature(Secret, Header, Body)).

verify_signature_rejects_wrong_secret(_Config) ->
    Body = ~"{\"action\":\"opened\"}",
    Hex = hmac_sha256_hex(~"correct-secret", Body),
    Header = <<"sha256=", Hex/binary>>,
    ?assertNot(gakudan_tickets_github:verify_signature(~"wrong-secret", Header, Body)).

verify_signature_rejects_missing_prefix(_Config) ->
    ?assertNot(gakudan_tickets_github:verify_signature(~"s", ~"abc123", ~"body")).

%% --- build_search_url ---

build_search_url_scopes_to_repo(_Config) ->
    Ref = gakudan_tickets_github:source(#{
        owner => ~"Taure",
        repo => ~"gakudan",
        token => ~"unused-in-this-test"
    }),
    Url = gakudan_tickets_github:build_search_url(Ref, ~"is:open label:bug"),
    UrlBin = iolist_to_binary(Url),
    ?assert(binary:match(UrlBin, ~"/search/issues?q=") =/= nomatch),
    ?assert(binary:match(UrlBin, ~"repo%3ATaure%2Fgakudan") =/= nomatch),
    ?assert(binary:match(UrlBin, ~"is%3Aopen") =/= nomatch).

%% --- source ---

source_carries_required_fields(_Config) ->
    Ref = gakudan_tickets_github:source(#{
        owner => ~"Taure",
        repo => ~"gakudan",
        token => ~"sometoken"
    }),
    ?assertEqual(~"Taure", maps:get(owner, Ref)),
    ?assertEqual(~"gakudan", maps:get(repo, Ref)),
    ?assertEqual(~"sometoken", maps:get(token, Ref)),
    ?assertEqual(~"https://api.github.com", maps:get(base_url, Ref)).

source_with_app_config_carries_app_field(_Config) ->
    Ref = gakudan_tickets_github:source(#{
        owner => ~"Taure",
        repo => ~"gakudan",
        app => #{
            app_id => 12345,
            private_key_pem =>
                ~"-----BEGIN RSA PRIVATE KEY-----\nstub\n-----END RSA PRIVATE KEY-----\n",
            installation_id => 67890
        }
    }),
    ?assertEqual(~"Taure", maps:get(owner, Ref)),
    ?assertEqual(~"gakudan", maps:get(repo, Ref)),
    ?assertNot(maps:is_key(token, Ref)),
    ?assert(maps:is_key(app, Ref)),
    AppCfg = maps:get(app, Ref),
    ?assertEqual(12345, maps:get(app_id, AppCfg)),
    ?assertEqual(67890, maps:get(installation_id, AppCfg)).

%% --- transition rejects bad input ---

transition_rejects_unsupported_state(_Config) ->
    Ref = gakudan_tickets_github:source(#{
        owner => ~"Taure",
        repo => ~"gakudan",
        token => ~"unused"
    }),
    {error, {unsupported_state, in_progress}} =
        gakudan_tickets_github:transition(Ref, ~"1", in_progress).

%% --- parse_file_contents ---

parse_file_contents_decodes_base64(_Config) ->
    Original = ~"hello world\n",
    Encoded = base64:encode(Original),
    Response = #{
        ~"type" => ~"file",
        ~"encoding" => ~"base64",
        ~"content" => Encoded
    },
    {ok, Original} = gakudan_tickets_github:parse_file_contents(Response).

parse_file_contents_strips_newlines_from_base64(_Config) ->
    Original = binary:copy(~"abcdefgh", 20),
    EncodedFlat = base64:encode(Original),
    EncodedWrapped = wrap_every_n(EncodedFlat, 60),
    ?assertNotEqual(EncodedFlat, EncodedWrapped),
    Response = #{
        ~"type" => ~"file",
        ~"encoding" => ~"base64",
        ~"content" => EncodedWrapped
    },
    {ok, Original} = gakudan_tickets_github:parse_file_contents(Response).

parse_file_contents_rejects_directory_listing(_Config) ->
    {error, is_directory} = gakudan_tickets_github:parse_file_contents([
        #{~"type" => ~"file", ~"name" => ~"a.txt"},
        #{~"type" => ~"file", ~"name" => ~"b.txt"}
    ]),
    {error, is_directory} = gakudan_tickets_github:parse_file_contents(#{
        ~"type" => ~"dir",
        ~"name" => ~"docs"
    }).

parse_file_contents_rejects_too_large_file(_Config) ->
    Response = #{
        ~"type" => ~"file",
        ~"encoding" => ~"none",
        ~"size" => 5_000_000,
        ~"download_url" => ~"https://raw.githubusercontent.com/x/y/main/big"
    },
    {error, too_large} = gakudan_tickets_github:parse_file_contents(Response).

parse_file_contents_rejects_unknown_shape(_Config) ->
    {error, unexpected_shape} = gakudan_tickets_github:parse_file_contents(#{
        ~"type" => ~"submodule"
    }).

%% --- parse_labels_response ---

parse_labels_response_normalises_each_label(_Config) ->
    Raw = [
        #{~"name" => ~"bug", ~"description" => ~"It broke", ~"color" => ~"d73a4a"},
        #{~"name" => ~"docs", ~"description" => ~"Docs only", ~"color" => ~"0075ca"}
    ],
    [Bug, Docs] = gakudan_tickets_github:parse_labels_response(Raw),
    ?assertEqual(~"bug", maps:get(name, Bug)),
    ?assertEqual(~"It broke", maps:get(description, Bug)),
    ?assertEqual(~"d73a4a", maps:get(color, Bug)),
    ?assertEqual(~"docs", maps:get(name, Docs)).

parse_labels_response_handles_null_description(_Config) ->
    Raw = [
        #{~"name" => ~"wontfix", ~"description" => null, ~"color" => ~"ffffff"}
    ],
    [L] = gakudan_tickets_github:parse_labels_response(Raw),
    ?assertEqual(~"wontfix", maps:get(name, L)),
    ?assertEqual(~"", maps:get(description, L)).

%% --- helpers ---

hmac_sha256_hex(Secret, Body) ->
    Hash = crypto:mac(hmac, sha256, Secret, Body),
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash]).

wrap_every_n(Bin, N) when is_binary(Bin), is_integer(N), N > 0 ->
    wrap_every_n(Bin, N, []).

wrap_every_n(<<>>, _N, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
wrap_every_n(Bin, N, Acc) when byte_size(Bin) =< N ->
    iolist_to_binary(lists:reverse([Bin | Acc]));
wrap_every_n(Bin, N, Acc) ->
    Chunk = binary:part(Bin, 0, N),
    Rest = binary:part(Bin, N, byte_size(Bin) - N),
    wrap_every_n(Rest, N, [~"\n", Chunk | Acc]).
