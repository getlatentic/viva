%% B16 arm 2: what does collection cost when BEAM does it its own way?
%%
%% No forced global collection. Sessions allocate by holding a conversation
%% that grows, and each process is collected when it needs to be. The question
%% is whether any single collection stalls anything for long enough to matter.
%%
%% Measured from INSIDE the VM. SYSTEM_MONITOR reports every collection that
%% runs past a threshold, so the answer does not depend on a bystander process
%% competing for the same busy schedulers -- which is what defeated five
%% earlier attempts at this from outside.
-module(b16_run).
-export([main/0]).

-define(LONG_GC_MS, 1).
-define(TURNS, 12).

body() -> list_to_binary(lists:duplicate(400, $x)).

main() ->
    {ok, _} = b16_sup:start_link(),
    erlang:system_monitor(self(), [{long_gc, ?LONG_GC_MS}]),
    io:format("  every collection over ~wms is reported by the VM itself~n~n", [?LONG_GC_MS]),
    io:format("  ~8s ~9s ~10s ~10s ~9s~n",
              ["sessions", "all GCs", "over 1ms", "worst ms", "heap MB"]),
    run([500, 1000, 2000, 4000, 8000], 0, []),
    ok.

run([], _Made, _Pids) -> ok;
run([Target | Rest], Made, Pids) ->
    New = [begin {ok, P} = b16_sup:start_session(N), P end
           || N <- lists:seq(Made + 1, Target)],
    All = Pids ++ New,
    drain(),
    Body = body(),
    %% Churn: every session grows its conversation, so collection happens
    %% because the processes allocated, not because we told them to.
    [ [b16_session:say(P, Body) || P <- All] || _ <- lists:seq(1, ?TURNS) ],
    _ = [b16_session:depth(P) || P <- All],   % barrier: all casts applied
    timer:sleep(300),
    {Count, Worst, _Total} = collect(0, 0, 0),
    %% PROOF THE MECHANISM FIRED. Zero long collections means nothing if no
    %% collection happened: binaries over 64 bytes live off-heap, so a
    %% conversation of them can leave the process heap small enough never to
    %% need collecting, and the probe would report a clean zero having tested
    %% nothing at all.
    {GCs, _, _} = erlang:statistics(garbage_collection),
    io:format("  ~8w ~9w ~10w ~10w ~9w~n",
              [Target, GCs, Count, Worst, erlang:memory(total) div 1048576]),
    run(Rest, Target, All).

drain() -> receive _ -> drain() after 0 -> ok end.

collect(Count, Worst, Total) ->
    receive
        {monitor, _Pid, long_gc, Info} ->
            Ms = proplists:get_value(timeout, Info, 0),
            collect(Count + 1, max(Worst, Ms), Total + Ms)
    after 0 -> {Count, Worst, Total}
    end.
