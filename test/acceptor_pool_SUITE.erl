-module(acceptor_pool_SUITE).

-include_lib("common_test/include/ct.hrl").

-define(TIMEOUT, 5000).

%% common_test api

-export([all/0,
         suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2]).

%% test cases

-export([accept/1,
         close_listener/1]).

%% common_test api

all() ->
    [accept, close_listener].

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
    {ok, Ref} = acceptor_pool:attach(Pool, LSock, 1),
    Connect = fun() -> gen_tcp:connect("localhost", Port, Opts, ?TIMEOUT) end,
    [{connect, Connect}, {pool, Pool}, {ref, Ref}, {listener, LSock} | Config].

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

close_listener(Config) ->
    Connect = ?config(connect, Config),
    {ok, ClientA} = Connect(),

    LSock = ?config(listener, Config),
    ok = gen_tcp:close(LSock),

    {error, _} = Connect(),

    ok = gen_tcp:send(ClientA, "hello"),
    {ok, "hello"} = gen_tcp:recv(ClientA, 0, ?TIMEOUT),
    ok = gen_tcp:close(ClientA),

    ok.
