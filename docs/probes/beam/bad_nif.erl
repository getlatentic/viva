%%% Loader for the non-yielding NIF. block/1 is replaced by the native
%%% implementation once the shared object loads; the stub is what runs if the
%%% load failed, and it says so rather than silently passing.

-module(bad_nif).
-export([block/1, block_dirty/1]).
-on_load(init/0).

init() ->
    Dir = filename:dirname(code:which(?MODULE)),
    erlang:load_nif(filename:join(Dir, "bad_nif"), 0).

block(_Seconds) ->
    erlang:nif_error(nif_not_loaded).

%% Same busy loop, scheduled onto a dirty CPU scheduler.
block_dirty(_Seconds) ->
    erlang:nif_error(nif_not_loaded).
