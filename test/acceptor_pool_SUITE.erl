-module(acceptor_pool_SUITE).

-include_lib("common_test/include/ct.hrl").

-define(TIMEOUT, 5000).

%% common_test api

-export([all/0,
         groups/0,
         suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2]).

%% test cases

-export([accept/1,
         close_socket/1,
         which_sockets/1,
         which_children/1,
         count_children/1,
         format_status/1]).

%% common_test api

all() ->
    [{group, tcp}, {group, supervisor}].

groups() ->
    [{tcp, [parallel], [accept, close_socket, which_sockets]},
     {supervisor, [parallel], [which_children, count_children, format_status]}].

suite() ->
    [{timetrap, {seconds, 15}}].

init_per_suite(Config) ->
    {ok, Started} = application:ensure_all_started(acceptor_pool),
    [{started, Started} | Config].

end_per_suite(Config) ->
    Started = ?config(started, Config),
    _ = [application:stop(App) || App <- Started],
    ok.

init_per_testcase(_TestCase, Config) ->
    Opts = [{active, false}, {packet, 4}],
    {ok, LSock} = gen_tcp:listen(0, Opts),
    {ok, Port} = inet:port(LSock),
    {ok, Pool} = acceptor_pool_test:start_link([{accept_timeout, ?TIMEOUT}]),
    {ok, Ref} = acceptor_pool:attach_socket(Pool, LSock, 1),
    Connect = fun() -> gen_tcp:connect("localhost", Port, Opts, ?TIMEOUT) end,
    [{connect, Connect}, {pool, Pool}, {ref, Ref}, {socket, LSock} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%% test cases

accept(Config) ->
    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientA),

    ok.

close_socket(Config) ->
    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    LSock = ?config(socket, Config),
    ok = gen_tcp:close(LSock),

    {error, _} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientA),

    ok.

which_sockets(Config) ->
    LSock = ?config(socket, Config),
    {ok, Port} = inet:port(LSock),
    Ref = ?config(ref, Config),
    Pool = ?config(pool, Config),

    [{inet_tcp, {_, Port}, LSock, Ref}] = acceptor_pool:which_sockets(Pool),

    ok.

which_children(Config) ->
    Pool = ?config(pool, Config),

    [] = acceptor_pool:which_children(Pool),

    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    [{{acceptor_pool_test, {_, _}, {_,_}, _}, Pid, worker,
      [acceptor_pool_test]}] = acceptor_pool:which_children(Pool),

    Ref = monitor(process, Pid),

    ok = gen_tcp:close(ClientA),

    receive {'DOWN', Ref, _, _, _} -> ok end,

    [] = acceptor_pool:which_children(Pool),

    ok.

count_children(Config) ->
    Pool = ?config(pool, Config),

    % workers is 1 because 1 acceptor
    [{specs, 1}, {active, 0}, {supervisors, 0}, {workers, 1}] =
        acceptor_pool:count_children(Pool),

    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),

    % workers is 2 because 1 active connection and 1 acceptor
    [{specs, 1}, {active, 1}, {supervisors, 0}, {workers, 2}] =
        acceptor_pool:count_children(Pool),

    [{_, Pid, _, _}] = acceptor_pool:which_children(Pool),

    Ref = monitor(process, Pid),

    ok = gen_tcp:close(ClientA),

    receive {'DOWN', Ref, _, _, _} -> ok end,

    % workers is 1 because 1 acceptor
    [{specs, 1}, {active, 0}, {supervisors, 0}, {workers, 1}] =
        acceptor_pool:count_children(Pool),

    ok.

format_status(Config) ->
    Pool = ?config(pool, Config),

    {status, Pool, {module, _}, Items} = sys:get_status(Pool),

    [_PDict, running, _Parent, [], Misc] = Items,

    {supervisor, [{"Callback", acceptor_pool_test}]} =
        lists:keyfind(supervisor, 1, Misc),

    ok.
