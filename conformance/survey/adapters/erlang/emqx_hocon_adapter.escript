#!/usr/bin/env escript
%% adapter: emqx/hocon (Erlang) — run.sh contract (path in, compact JSON out, non-zero on rejection)
main(["--version"]) -> io:format("emqx/hocon 7759b15~n");
main([Path]) ->
    [code:add_patha(D) || D <- filelib:wildcard("/tmp/impl/emqx_hocon/_build/default/lib/*/ebin")],
    try hocon:load(Path) of
        {ok, M} -> io:put_chars(json:encode(conv(M))), io:nl(), halt(0);
        {error, E} -> io:format(standard_error, "ERROR ~p~n", [E]), halt(1)
    catch C:R -> io:format(standard_error, "ERROR ~p:~p~n", [C, R]), halt(1)
    end.
conv(M) when is_map(M) -> maps:from_list([{to_bin(K), conv(V)} || {K, V} <- maps:to_list(M)]);
conv(L) when is_list(L) -> [conv(X) || X <- L];
conv(null) -> null;
conv(B) when is_binary(B) -> B;
conv(X) -> X.
to_bin(K) when is_binary(K) -> K;
to_bin(K) when is_atom(K) -> atom_to_binary(K);
to_bin(K) -> iolist_to_binary(io_lib:format("~p", [K])).
