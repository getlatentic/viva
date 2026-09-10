%% Sessions under supervision, started on demand.
-module(b16_sup).
-behaviour(supervisor).
-export([start_link/0, start_session/1, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_session(Id) -> supervisor:start_child(?MODULE, [Id]).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 5, period => 10},
          [#{id => session,
             start => {b16_session, start_link, []},
             restart => temporary, shutdown => 5000, type => worker,
             modules => [b16_session]}]}}.
