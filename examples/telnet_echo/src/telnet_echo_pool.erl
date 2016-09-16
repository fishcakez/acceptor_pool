-module(telnet_echo_pool).

-behaviour(acceptor_pool).

%% public api

-export([start_link/0]).
-export([attach/2]).

%% acceptor_pool api

-export([init/1]).

%% public api

start_link() ->
    acceptor_pool:start_link({local, ?MODULE}, ?MODULE, []).

attach(Socket, Acceptors) ->
    acceptor_pool:attach(?MODULE, Socket, Acceptors).

%% acceptor_pool api

init([]) ->
    Conn = #{id => telnet_echo_conn,
             start => {telnet_echo_conn, [], []}},
    {ok, {#{}, [Conn]}}.
