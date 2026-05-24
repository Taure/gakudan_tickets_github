-module(gakudan_tickets_github_jwt).
-moduledoc """
RS256-signed JWT builder for GitHub App authentication.

GitHub App auth uses a short-lived JWT signed with the App's private key
to request installation access tokens. This module produces those JWTs.

Per GitHub's documentation, the JWT must:
- Use RS256 algorithm.
- Set `iss` to the App ID.
- Have `iat` no further than 60s in the past (clock skew tolerance).
- Have `exp` no more than 10 minutes after `iat`.

This builder uses `iat = NowSec - 60` and `exp = NowSec + 540` (9 minutes
after Now) to stay safely inside the bounds.
""".

-export([build/3]).

-spec build(AppId :: integer(), PrivateKeyPem :: binary(), NowSec :: integer()) -> binary().
build(AppId, PrivateKeyPem, NowSec) when
    is_integer(AppId), is_binary(PrivateKeyPem), is_integer(NowSec)
->
    Header = #{alg => ~"RS256", typ => ~"JWT"},
    Claims = #{
        iat => NowSec - 60,
        exp => NowSec + 540,
        iss => AppId
    },
    HeaderB64 = base64url_encode(iolist_to_binary(json:encode(Header))),
    ClaimsB64 = base64url_encode(iolist_to_binary(json:encode(Claims))),
    Signing = <<HeaderB64/binary, $., ClaimsB64/binary>>,
    Key = decode_pem_key(PrivateKeyPem),
    Sig = public_key:sign(Signing, sha256, Key),
    SigB64 = base64url_encode(Sig),
    <<Signing/binary, $., SigB64/binary>>.

base64url_encode(Bin) ->
    Encoded = base64:encode(Bin, #{padding => false}),
    binary:replace(
        binary:replace(Encoded, ~"+", ~"-", [global]),
        ~"/",
        ~"_",
        [global]
    ).

decode_pem_key(Pem) ->
    [Entry | _] = public_key:pem_decode(Pem),
    public_key:pem_entry_decode(Entry).
