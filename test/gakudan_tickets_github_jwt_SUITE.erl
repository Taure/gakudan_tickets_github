-module(gakudan_tickets_github_jwt_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    jwt_has_three_segments/1,
    jwt_header_is_rs256/1,
    jwt_claims_carry_app_id/1,
    jwt_iat_has_clock_skew_buffer/1,
    jwt_exp_is_within_ten_minutes_per_github/1,
    jwt_signature_verifies_with_public_key/1,
    jwt_signing_is_deterministic_for_same_inputs/1
]).

all() ->
    [
        jwt_has_three_segments,
        jwt_header_is_rs256,
        jwt_claims_carry_app_id,
        jwt_iat_has_clock_skew_buffer,
        jwt_exp_is_within_ten_minutes_per_github,
        jwt_signature_verifies_with_public_key,
        jwt_signing_is_deterministic_for_same_inputs
    ].

init_per_suite(Config) ->
    {PrivKey, PubKey, Pem} = generate_keypair(),
    [{priv_key, PrivKey}, {pub_key, PubKey}, {pem, Pem} | Config].

end_per_suite(_Config) ->
    ok.

jwt_has_three_segments(Config) ->
    Pem = ?config(pem, Config),
    Jwt = gakudan_tickets_github_jwt:build(1234, Pem, 1000000),
    Parts = binary:split(Jwt, ~".", [global]),
    ?assertEqual(3, length(Parts)).

jwt_header_is_rs256(Config) ->
    Pem = ?config(pem, Config),
    Jwt = gakudan_tickets_github_jwt:build(1234, Pem, 1000000),
    [HeaderB64 | _] = binary:split(Jwt, ~".", [global]),
    Header = json:decode(base64url_decode(HeaderB64)),
    ?assertEqual(~"RS256", maps:get(~"alg", Header)),
    ?assertEqual(~"JWT", maps:get(~"typ", Header)).

jwt_claims_carry_app_id(Config) ->
    Pem = ?config(pem, Config),
    Jwt = gakudan_tickets_github_jwt:build(42, Pem, 1000000),
    Claims = decode_claims(Jwt),
    ?assertEqual(42, maps:get(~"iss", Claims)).

jwt_iat_has_clock_skew_buffer(Config) ->
    Pem = ?config(pem, Config),
    Now = 1000000,
    Jwt = gakudan_tickets_github_jwt:build(1, Pem, Now),
    Claims = decode_claims(Jwt),
    %% GitHub allows up to 60s clock skew; we subtract 60s from Now
    ?assertEqual(Now - 60, maps:get(~"iat", Claims)).

jwt_exp_is_within_ten_minutes_per_github(Config) ->
    Pem = ?config(pem, Config),
    Now = 1000000,
    Jwt = gakudan_tickets_github_jwt:build(1, Pem, Now),
    Claims = decode_claims(Jwt),
    Iat = maps:get(~"iat", Claims),
    Exp = maps:get(~"exp", Claims),
    %% GitHub rejects JWTs with exp - iat > 600s
    ?assert(Exp - Iat =< 600).

jwt_signature_verifies_with_public_key(Config) ->
    Pem = ?config(pem, Config),
    PubKey = ?config(pub_key, Config),
    Jwt = gakudan_tickets_github_jwt:build(1, Pem, 1000000),
    [H, C, S] = binary:split(Jwt, ~".", [global]),
    Signing = <<H/binary, $., C/binary>>,
    Sig = base64url_decode(S),
    ?assert(public_key:verify(Signing, sha256, Sig, PubKey)).

jwt_signing_is_deterministic_for_same_inputs(Config) ->
    Pem = ?config(pem, Config),
    Jwt1 = gakudan_tickets_github_jwt:build(1, Pem, 1000000),
    Jwt2 = gakudan_tickets_github_jwt:build(1, Pem, 1000000),
    %% PKCS#1 v1.5 RSA-SHA256 is deterministic
    ?assertEqual(Jwt1, Jwt2).

%% --- helpers ---

generate_keypair() ->
    PrivKey = public_key:generate_key({rsa, 1024, 65537}),
    PubKey = #'RSAPublicKey'{
        modulus = PrivKey#'RSAPrivateKey'.modulus,
        publicExponent = PrivKey#'RSAPrivateKey'.publicExponent
    },
    PemEntry = public_key:pem_entry_encode('RSAPrivateKey', PrivKey),
    Pem = public_key:pem_encode([PemEntry]),
    {PrivKey, PubKey, Pem}.

decode_claims(Jwt) ->
    [_HeaderB64, ClaimsB64 | _] = binary:split(Jwt, ~".", [global]),
    json:decode(base64url_decode(ClaimsB64)).

base64url_decode(B) ->
    Padded = pad(
        binary:replace(
            binary:replace(B, ~"-", ~"+", [global]),
            ~"_",
            ~"/",
            [global]
        )
    ),
    base64:decode(Padded).

pad(B) ->
    case byte_size(B) rem 4 of
        0 -> B;
        N -> <<B/binary, (binary:copy(~"=", 4 - N))/binary>>
    end.
