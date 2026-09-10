%% One viva session, as OTP would build it: a gen_server holding a conversation.
-module(b16_session).
-behaviour(gen_server).
-export([start_link/1, say/2, depth/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Id) -> gen_server:start_link(?MODULE, Id, []).
say(Pid, Text) -> gen_server:cast(Pid, {say, Text}).
depth(Pid) -> gen_server:call(Pid, depth, 30000).

init(Id) -> {ok, #{id => Id, messages => []}}.

%% A conversation: maps with binary content, which is what the collector
%% actually has to deal with. A list of integers is not a session.
handle_cast({say, Text}, S = #{messages := M}) ->
    {noreply, S#{messages := [#{role => <<"user">>, content => Text} | M]}};
handle_cast(_, S) -> {noreply, S}.

handle_call(depth, _From, S = #{messages := M}) -> {reply, length(M), S};
handle_call(_, _From, S) -> {reply, ok, S}.

handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
