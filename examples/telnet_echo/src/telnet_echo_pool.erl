-module(telnet_echo_pool).

-behaviour(acceptor_pool).

%% public api

-export([start_link/0]).
-export([accept_socket/2]).

%% acceptor_pool api

-export([init/1]).

%% public api

start_link() ->
    acceptor_pool:start_link({local, ?MODULE}, ?MODULE, []).

accept_socket(Socket, Acceptors) ->
    acceptor_pool:accept_socket(?MODULE, Socket, Acceptors).

%% acceptor_pool api

init([]) ->
    Conn = #{id => telnet_echo_conn,
             start => {telnet_echo_conn, [], []},
             grace => 5000}, % Give connections 5000ms to close before shutdown
    {ok, {#{}, [Conn]}}.
