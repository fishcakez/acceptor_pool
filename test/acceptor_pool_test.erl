-module(acceptor_pool_test).

-behaviour(acceptor_pool).
-behaviour(acceptor).

-export([start_link/1]).

-export([init/1]).

-export([init/3,
         enter_loop/2,
         terminate/2]).

start_link(Opts) ->
    acceptor_pool:start_link(?MODULE, Opts).

init(Opts) ->
    {ok, #{}, [#{id => ?MODULE, start => {?MODULE, [], Opts}}]}.


init(_, _, []) ->
    {ok, undefined}.

enter_loop(Socket, undefined) ->
    loop(Socket).

terminate(_, _) ->
    ok.

loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            _ = gen_tcp:send(Socket, Data),
            loop(Socket);
        {error, Reason} ->
            gen_tcp:close(Socket),
            error(Reason, [Socket])
    end.
