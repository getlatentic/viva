%%% B8 axis 3 -- does forward migration buy enough over explicit externalised
%%% state plus clean retraction to justify its complexity?
%%%
%%% B12 measured what RevertAndReapply costs: component-local state does not
%%% survive replacement, while the same state one indirection away in a
%%% longer-lived dependency survives at zero cost. So this is a real comparison
%%% now, not a description of two mechanisms:
%%%
%%%   OTP     MigrateState       old state -> code_change/3 -> new state
%%%   vivarium/Cordis            state lives outside the replaceable component
%%%
%%% THE AGENT DRIVES EVERY UPGRADE. Module source is generated as text at
%%% runtime, compiled, loaded, and migrated through sys:change_code -- no release
%%% script, no appup, no relup. Otherwise this would measure that OTP release
%%% upgrades work, which nobody doubts and which is not the question.
%%%
%%% THE ARM THAT MATTERS is the WRONG transformation. B12 found that Cordis
%%% trusts the inverse a component supplies and reports a clean unload when it is
%%% wrong. If OTP likewise trusts code_change/3, the gap is not a property of
%%% Cordis -- it is a property of every runtime that lets a component describe
%%% its own transition, and reconciliation is substrate-independent.

-module(migration_probe).

-export([main/0, run/1]).

-define(GOAL, <<"repair sum-invoice">>).
-define(CANDIDATES, [alpha, beta, gamma]).
-define(EVIDENCE, [{alpha, 0.4}, {beta, 0.9}]).
-define(PARTIAL, <<"tax applied before discount">>).

main() ->
    Arms = [migrate_correct, migrate_wrong, externalise_correct, externalise_wrong],
    [io:format("RESULT ~p~n", [run(Arm)]) || Arm <- Arms],
    halt(0).

run(Arm) ->
    Dir = "/tmp/b8-migration-" ++ atom_to_list(Arm),
    file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    true = code:add_patha(Dir),
    Result = arm(Arm, Dir),
    [{arm, Arm} | Result].

%%% ------------------------------------------- OTP: forward state migration ---

arm(Kind, Dir) when Kind =:= migrate_correct; Kind =:= migrate_wrong ->
    Correct = (Kind =:= migrate_correct),
    Steps0 = generate(Dir, agent_state, v1_source()),
    {ok, Pid} = agent_state:start_link(),
    agent_state:seed(?GOAL, ?CANDIDATES, ?EVIDENCE, ?PARTIAL),
    Before = agent_state:inspect(),

    %% The agent writes v2, compiles it, and drives the migration itself.
    Steps1 = generate(Dir, agent_state, v2_source(Correct)),
    ok = sys:suspend(Pid),
    ok = sys:change_code(Pid, agent_state, "1", []),
    ok = sys:resume(Pid),

    After = agent_state:inspect(),
    Survived = is_process_alive(Pid),
    StillServes = attempt(fun () -> agent_state:score(beta) end),
    gen_server:stop(Pid),
    [{mechanism, 'code_change/3'},
     {agent_driven_steps, Steps0 + Steps1 + 3},
     {process_identity_preserved, Survived},
     {state_before, Before},
     {state_after, After},
     {still_serves_after_migration, StillServes},
     {runtime_reported_a_problem, false},
     {reconciliation, reconcile(After)}];

%%% -------------------------- vivarium/Cordis: externalised state + restart ---
%%%
%%% The store is the longer-lived dependency. The component that uses it is
%%% replaced wholesale -- stopped, not migrated -- and the replacement reads what
%%% it needs from the store. No transformation function exists to be wrong; the
%%% failure mode moves to the READER, which is what the wrong arm exercises.

arm(Kind, Dir) when Kind =:= externalise_correct; Kind =:= externalise_wrong ->
    Correct = (Kind =:= externalise_correct),
    Steps0 = generate(Dir, agent_store, store_source()),
    {ok, Store} = agent_store:start_link(),
    agent_store:put(goal, ?GOAL),
    agent_store:put(candidates, ?CANDIDATES),
    agent_store:put(evidence, ?EVIDENCE),
    agent_store:put(partial, ?PARTIAL),

    Steps1 = generate(Dir, agent_worker, worker_source(1, true)),
    {ok, W1} = agent_worker:start_link(),
    Before = agent_worker:inspect(),
    gen_server:stop(W1),

    Steps2 = generate(Dir, agent_worker, worker_source(2, Correct)),
    {ok, W2} = agent_worker:start_link(),
    After = agent_worker:inspect(),
    StillServes = attempt(fun () -> agent_worker:score(beta) end),
    gen_server:stop(W2),
    gen_server:stop(Store),
    [{mechanism, 'externalised store + restart'},
     {agent_driven_steps, Steps0 + Steps1 + Steps2 + 2},
     {process_identity_preserved, false},
     {state_before, Before},
     {state_after, After},
     {still_serves_after_migration, StillServes},
     {runtime_reported_a_problem, false},
     {reconciliation, reconcile(After)}].

attempt(Fun) ->
    try Fun() catch Class:Reason -> {Class, Reason} end.

%%% ------------------------------------------------------------ the ledger ---
%%%
%%% What the authoritative record says the agent's state contains, independent of
%%% which mechanism carried it across. Anything the projection and the runtime
%%% disagree on is a failed transition, exactly as in B12.

reconcile(Actual) ->
    Expected = #{goal => ?GOAL,
                 candidate_names => lists:sort(?CANDIDATES),
                 evidence_count => length(?EVIDENCE),
                 partial => ?PARTIAL},
    Divergences = [{K, maps:get(K, Expected), maps:get(K, Actual, missing)}
                   || K <- maps:keys(Expected),
                      maps:get(K, Actual, missing) =/= maps:get(K, Expected)],
    case Divergences of
        [] -> [{verdict, matches_ledger}];
        _ -> [{verdict, 'FAILED TRANSITION'}, {divergences, Divergences}]
    end.

%%% ------------------------------------------- agent-generated module source ---

generate(Dir, Module, Source) ->
    Path = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
    ok = file:write_file(Path, Source),
    {ok, Module, Bin} = compile:file(Path, [binary, return_errors]),
    code:purge(Module),
    {module, Module} = code:load_binary(Module, Path, Bin),
    2. % write + compile-and-load, counted as agent-driven steps

v1_source() -> <<"
-module(agent_state).
-behaviour(gen_server).
-export([start_link/0, seed/4, inspect/0, score/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
seed(G, C, E, P) -> gen_server:call(?MODULE, {seed, G, C, E, P}).
inspect() -> gen_server:call(?MODULE, inspect).
score(_) -> not_supported_in_v1.
init([]) -> {ok, #{goal => undefined, candidates => [], evidence => [], partial => undefined}}.
handle_call({seed, G, C, E, P}, _F, _S) ->
  {reply, ok, #{goal => G, candidates => C, evidence => E, partial => P}};
handle_call(inspect, _F, S) ->
  {reply, #{goal => maps:get(goal, S),
            candidate_names => lists:sort(maps:get(candidates, S)),
            evidence_count => length(maps:get(evidence, S)),
            partial => maps:get(partial, S)}, S}.
handle_cast(_M, S) -> {noreply, S}.
code_change(_V, S, _E) -> {ok, S}.
">>.

%% v2 changes the candidate representation from a list to a scored map, which is
%% the shape change a real self-edit produces. The WRONG variant also drops
%% evidence -- an omission, not a corruption, because that is what an author
%% actually gets wrong.
v2_source(Correct) ->
    Migration = case Correct of
        true -> <<"
code_change(_V, S, _E) ->
  Cs = maps:get(candidates, S),
  {ok, S#{candidates => maps:from_list([{C, 0.0} || C <- Cs])}}.">>;
        false -> <<"
code_change(_V, S, _E) ->
  Cs = maps:get(candidates, S),
  {ok, S#{candidates => maps:from_list([{C, 0.0} || C <- Cs]), evidence => []}}.">>
    end,
    <<"
-module(agent_state).
-behaviour(gen_server).
-export([start_link/0, seed/4, inspect/0, score/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
seed(G, C, E, P) -> gen_server:call(?MODULE, {seed, G, C, E, P}).
inspect() -> gen_server:call(?MODULE, inspect).
score(C) -> gen_server:call(?MODULE, {score, C}).
init([]) -> {ok, #{goal => undefined, candidates => #{}, evidence => [], partial => undefined}}.
handle_call({seed, G, C, E, P}, _F, _S) ->
  {reply, ok, #{goal => G, candidates => C, evidence => E, partial => P}};
handle_call({score, C}, _F, S) ->
  {reply, maps:get(C, maps:get(candidates, S), absent), S};
handle_call(inspect, _F, S) ->
  {reply, #{goal => maps:get(goal, S),
            candidate_names => lists:sort(maps:keys(maps:get(candidates, S))),
            evidence_count => length(maps:get(evidence, S)),
            partial => maps:get(partial, S)}, S}.
handle_cast(_M, S) -> {noreply, S}.
", Migration/binary, "
">>.

store_source() -> <<"
-module(agent_store).
-behaviour(gen_server).
-export([start_link/0, put/2, get/1]).
-export([init/1, handle_call/3, handle_cast/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
put(K, V) -> gen_server:call(?MODULE, {put, K, V}).
get(K) -> gen_server:call(?MODULE, {get, K}).
init([]) -> {ok, #{}}.
handle_call({put, K, V}, _F, S) -> {reply, ok, S#{K => V}};
handle_call({get, K}, _F, S) -> {reply, maps:get(K, S, missing), S}.
handle_cast(_M, S) -> {noreply, S}.
">>.

%% The replacement reads what it needs from the store. The WRONG variant reads
%% the wrong key -- the reader-side equivalent of a wrong inverse, and the only
%% place this arm can fail, since no transformation function exists.
worker_source(Version, Correct) ->
    EvidenceKey = case Correct of true -> <<"evidence">>; false -> <<"evidences">> end,
    V = integer_to_binary(Version),
    <<"
-module(agent_worker).
-behaviour(gen_server).
-export([start_link/0, inspect/0, score/1, version/0]).
-export([init/1, handle_call/3, handle_cast/2]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
inspect() -> gen_server:call(?MODULE, inspect).
score(C) -> gen_server:call(?MODULE, {score, C}).
version() -> ", V/binary, ".
init([]) -> {ok, []}.
handle_call({score, C}, _F, S) ->
  Cs = agent_store:get(candidates),
  {reply, case lists:member(C, Cs) of true -> 0.0; false -> absent end, S};
handle_call(inspect, _F, S) ->
  E = agent_store:get(", EvidenceKey/binary, "),
  {reply, #{goal => agent_store:get(goal),
            candidate_names => lists:sort(agent_store:get(candidates)),
            evidence_count => case E of missing -> 0; _ -> length(E) end,
            partial => agent_store:get(partial)}, S}.
handle_cast(_M, S) -> {noreply, S}.
">>.
