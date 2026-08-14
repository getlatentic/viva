%%% B8 axis 2 -- mutation impedance, the whole transaction rather than
%%% "Lisp forms versus Erlang tuples".
%%%
%%%   propose -> representation -> parse -> transform -> compile -> load ->
%%%   locate the affected process -> activate -> inspect
%%%
%%% SCORED SEPARATELY FOR TWO WORKLOADS, because vivarium does both and one
%%% averaged number would hide the effect:
%%%
%%%   GENERATION      write a definition that did not exist
%%%   TRANSFORMATION  change a definition that does exist, which requires
%%%                   READING IT BACK FIRST -- and that is where a structural
%%%                   representation should pay, if it pays anywhere
%%%
%%% WHAT THIS MEASURES: what the RUNTIME supplies for each step, and what it
%%% costs to get. WHAT IT DOES NOT MEASURE: model error rates on matched tasks.
%%% That needs the harness pointed at both substrates and is stated as an open
%%% gap rather than quietly folded in.

-module(impedance_probe).

-export([main/0]).

main() ->
    Dir = "/tmp/b8-impedance",
    file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    true = code:add_patha(Dir),
    io:format("RESULT ~p~n", [generation(Dir)]),
    io:format("RESULT ~p~n", [transformation(Dir, without_debug_info)]),
    io:format("RESULT ~p~n", [transformation(Dir, with_debug_info)]),
    halt(0).

%%% ------------------------------------------------------------ generation ---
%%%
%%% The agent writes a module that did not exist. Nothing has to be read back,
%%% so the representation question does not arise: the model emits SOURCE TEXT
%%% and the abstract format never reaches it. This is the story's outcome (a),
%%% and it is confirmed structurally rather than by opinion -- the whole path
%%% below is a binary of source and two library calls.

generation(Dir) ->
    Source = <<"
-module(fresh_capability).
-export([search/1]).
search(Q) -> {found, Q}.
">>,
    T0 = erlang:monotonic_time(microsecond),
    Path = filename:join(Dir, "fresh_capability.erl"),
    ok = file:write_file(Path, Source),
    {ok, fresh_capability, Bin} = compile:file(Path, [binary, return_errors]),
    {module, fresh_capability} = code:load_binary(fresh_capability, Path, Bin),
    Result = fresh_capability:search(<<"lisp">>),
    T1 = erlang:monotonic_time(microsecond),
    [{workload, generation},
     {representation_the_agent_writes, source_text},
     {abstract_format_reached_the_agent, false},
     {steps, ['file:write_file', 'compile:file', 'code:load_binary']},
     {microseconds, T1 - T0},
     {worked, Result =:= {found, <<"lisp">>}}].

%%% -------------------------------------------------------- transformation ---
%%%
%%% The agent changes a definition that already exists, which means reading it
%%% back out of the running system first. THIS IS THE STEP THAT SEPARATES THE
%%% SUBSTRATES, and BEAM's answer depends on a compile flag chosen earlier:
%%%
%%%   without debug_info   the source is NOT recoverable from the runtime. The
%%%                        agent must have kept it, or go back to the file.
%%%   with debug_info      beam_lib yields the ABSTRACT FORMAT -- a real AST,
%%%                        structurally transformable, but not the source and
%%%                        not what the agent wrote.
%%%
%%% Either way the round trip is lossy in a way SBCL's is not: a Lisp form read
%%% back is the same kind of object the agent produced. Measured here as what is
%%% RECOVERABLE and at what fidelity, which is checkable; the downstream claim
%%% about error rates is not tested by this probe.

transformation(Dir, Mode) ->
    Options = case Mode of
                  with_debug_info -> [binary, return_errors, debug_info];
                  without_debug_info -> [binary, return_errors]
              end,
    Source = <<"
-module(existing_capability).
-export([rank/1]).
rank(Xs) -> lists:sort(Xs).
">>,
    Path = filename:join(Dir, "existing_capability.erl"),
    ok = file:write_file(Path, Source),
    {ok, existing_capability, Bin} = compile:file(Path, Options),
    code:purge(existing_capability),
    {module, existing_capability} = code:load_binary(existing_capability, Path, Bin),

    %% Everything the agent can get back FROM THE RUNTIME, with the file ignored
    %% -- because a self-modifying system that has to consult its own source tree
    %% has left the image model, which is the comparison being made.
    Recovered = recover(Bin),
    [{workload, transformation},
     {mode, Mode},
     {recoverable_from_runtime, element(1, Recovered)},
     {fidelity, element(2, Recovered)},
     {round_trip_is_lossless, element(1, Recovered) =:= source_text}].

recover(Bin) ->
    case beam_lib:chunks(Bin, [abstract_code]) of
        {ok, {_, [{abstract_code, {_, Forms}}]}} when is_list(Forms) ->
            {abstract_format,
             [{forms, length(Forms)},
              {is_the_source_the_agent_wrote, false},
              {structurally_transformable, true},
              {reprintable_as_source, is_list(erl_prettypr_available(Forms))}]};
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            {nothing, [{reason, 'compiled without debug_info'},
                       {is_the_source_the_agent_wrote, false},
                       {structurally_transformable, false}]};
        Other ->
            {nothing, [{reason, Other}]}
    end.

%% Whether the abstract format can be printed back as compilable source at all.
%% erl_prettypr lives in syntax_tools, which is not guaranteed present, so this
%% reports its own availability rather than crashing the probe.
erl_prettypr_available(Forms) ->
    try
        [erl_prettypr:format(erl_syntax:form_list(Forms))]
    catch
        _:_ -> not_available
    end.
