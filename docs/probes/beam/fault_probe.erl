%%% B8 axis 1 -- the fault boundary.
%%%
%%% "Let it crash" is recited more often than it is measured. This probe installs
%%% a fault of a named class into a supervised system and asks two questions the
%%% slogan does not distinguish:
%%%
%%%   1. did the VICTIM die and get replaced?      -- what supervision promises
%%%   2. did the NODE survive and keep working?    -- what the agent needs
%%%
%%% The BYSTANDER is the instrument. It ticks on a timer and appends each tick to
%%% a file, so its progress is readable even when the node dies mid-run and
%%% nothing gets a chance to report. A fault that stops the ticks has crossed a
%%% boundary supervision does not defend, whatever the supervisor was told.
%%%
%%% Compare against SBCL fork, measured in E1: a forked child that corrupts its
%%% own heap cannot touch the parent, for ANY fault class, at 28-32ms per trial.
%%% That is the guarantee this gradient is being read against.

-module(fault_probe).
-behaviour(supervisor).

-export([main/1, init/1, run_bystander/1, run_victim/2]).

-define(SETTLE_MS, 1200).
-define(TICK_MS, 10).

%%% ---------------------------------------------------------------- entry ----

main([FaultAtom, HeartbeatPath]) ->
    Fault = list_to_atom(atom_to_list(FaultAtom)),
    Path = atom_to_list(HeartbeatPath),
    file:write_file(Path, <<>>),
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, [Fault, Path]),
    timer:sleep(?SETTLE_MS),
    report(Sup, Fault, Path),
    halt(0).

report(Sup, Fault, Path) ->
    Ticks = count_ticks(Path),
    Children = supervisor:which_children(Sup),
    VictimAlive = case lists:keyfind(victim, 1, Children) of
                      {victim, Pid, _, _} when is_pid(Pid) -> true;
                      _ -> false
                  end,
    Allocated = persistent_term:get({?MODULE, allocated}, not_applicable),
    io:format("RESULT ~p~n", [[{fault, Fault},
                               {node_survived, true},
                               {bystander_ticks, Ticks},
                               {victim_restarts, persistent_term:get({?MODULE, starts}, 0) - 1},
                               {victim_replaced_by_supervisor, VictimAlive},
                               {bytes_allocated_unopposed, Allocated}]]).

count_ticks(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> length(binary:matches(Bin, <<".">>));
        _ -> 0
    end.

%%% ----------------------------------------------------------- supervisor ----
%%%
%%% one_for_one so a victim crash is not allowed to reach the bystander by the
%%% supervision strategy itself -- any effect on the bystander is then the
%%% fault crossing a runtime boundary rather than a policy choice.

init([Fault, Path]) ->
    Flags = #{strategy => one_for_one, intensity => 10, period => 1},
    Bystander = #{id => bystander,
                  start => {?MODULE, run_bystander, [Path]},
                  restart => permanent, shutdown => brutal_kill, type => worker},
    Victim = #{id => victim,
               start => {?MODULE, run_victim, [Fault, Path]},
               restart => permanent, shutdown => brutal_kill, type => worker},
    {ok, {Flags, [Bystander, Victim]}}.

%%% ------------------------------------------------------------ bystander ----
%%%
%%% Unrelated work that must keep running. Each tick is a byte on disk, so the
%%% count survives a node that dies without reporting.

run_bystander(Path) ->
    {ok, spawn_link(fun () -> tick(Path) end)}.

tick(Path) ->
    file:write_file(Path, <<".">>, [append]),
    timer:sleep(?TICK_MS),
    tick(Path).

%%% --------------------------------------------------------------- victim ----

%% The fault fires ONCE. A victim that re-runs a deterministic crash on every
%% restart exhausts the supervisor's intensity limit within a second and takes
%% the whole tree down with it -- which reads as "the node died" and is an
%% artifact of the probe rather than a property of the fault. Firing once
%% separates the two: the supervisor gets to replace the victim exactly as it
%% would in a real system, and what remains is the fault's own reach.
run_victim(Fault, _Path) ->
    Starts = persistent_term:get({?MODULE, starts}, 0) + 1,
    persistent_term:put({?MODULE, starts}, Starts),
    Body = case Starts of
               1 -> fun () -> timer:sleep(100), fault(Fault) end;
               _ -> fun idle/0
           end,
    {ok, spawn_link(Body)}.

idle() ->
    timer:sleep(1000),
    idle().

%% Process-local by every account. The baseline the gradient is read against.
fault(exception) ->
    error(agent_generated_a_bug);

%% Pure Erlang cannot starve a scheduler: reduction counting preempts any loop
%% that stays inside the VM. This is the case BEAM is supposed to win.
fault(runaway) ->
    spin(0);

%% VM-global by construction. The atom table is not garbage collected and is not
%% partitioned per process, so one component exhausts it for everybody. The node
%% is started with a small +t so this terminates quickly.
fault(atom_exhaustion) ->
    exhaust_atoms(0);

%% VM-global-ish. The code server is a named singleton every module load goes
%% through; killing it is a thing a component can do to the whole node.
fault(code_server) ->
    exit(whereis(code_server), kill),
    timer:sleep(200),
    %% Prove the damage is real rather than nominal: try to use it.
    _ = code:load_file(lists),
    ok;

%% BEAM has no per-process memory ceiling by DEFAULT, and the opt-in one it does
%% have COVERS LESS THAN ITS NAME SUGGESTS. Three arms, because the first reading
%% of two of them was wrong: max_heap_size bounds the process HEAP, and binaries
%% over 64 bytes are reference-counted OUTSIDE it, so the cap does not bound the
%% allocation an agent generating a buffer is most likely to make.
%%
%% The arms are bounded by a PROBE BUDGET rather than run to VM abort. The
%% property under test is whether anything in the runtime intervenes, which is
%% answered by one process reaching gigabytes unopposed; driving the host into
%% swap to watch a documented abort would add nothing and cost the machine. The
%% budget is reported so the claim stays inside what was measured.
fault(memory) ->
    grow(binary, [], 0);

fault(memory_capped) ->
    cap_heap(),
    grow(binary, [], 0);

fault(memory_capped_heap) ->
    cap_heap(),
    grow(heap, [], 0);

%% The case that can take the scheduler, and the node, with it. A NIF runs
%% outside reduction counting, so nothing preempts it.
fault(bad_nif) ->
    bad_nif:block(1);

fault(bad_nif_saturate) ->
    N = erlang:system_info(schedulers),
    [spawn(fun () -> bad_nif:block(1) end) || _ <- lists:seq(1, N)],
    timer:sleep(60000);

%% The mitigation. Same busy loop on a DIRTY CPU scheduler, saturating every one
%% of them, so the question is whether normal schedulers keep running when the
%% dirty pool is fully occupied by native code that never returns.
fault(bad_nif_dirty_saturate) ->
    N = erlang:system_info(dirty_cpu_schedulers),
    [spawn(fun () -> bad_nif:block_dirty(1) end) || _ <- lists:seq(1, N)],
    timer:sleep(60000).

spin(N) -> spin(N + 1).

exhaust_atoms(N) ->
    _ = list_to_atom("agent_generated_atom_" ++ integer_to_list(N)),
    exhaust_atoms(N + 1).

-define(CHUNK_BYTES, 8388608).
-define(HEAP_CHUNK_WORDS, 400000).
-define(MEMORY_BUDGET_BYTES, 4294967296).

cap_heap() ->
    process_flag(max_heap_size, #{size => 1000000, kill => true, error_logger => false}).

grow(_Kind, _Acc, Total) when Total >= ?MEMORY_BUDGET_BYTES ->
    persistent_term:put({?MODULE, allocated}, Total),
    exit({probe_budget_reached, Total});
grow(binary, Acc, Total) ->
    persistent_term:put({?MODULE, allocated}, Total),
    grow(binary, [binary:copy(<<0:?CHUNK_BYTES>>) | Acc], Total + (?CHUNK_BYTES div 8));
grow(heap, Acc, Total) ->
    persistent_term:put({?MODULE, allocated}, Total),
    grow(heap, [lists:duplicate(?HEAP_CHUNK_WORDS, 0) | Acc], Total + (?HEAP_CHUNK_WORDS * 16)).
