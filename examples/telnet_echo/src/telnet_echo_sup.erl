-module(telnet_echo_sup).

-behaviour(supervisor).

%% public api

-export([start_link/0]).

%% supervisor api

-export([init/1]).

%% public api

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% supervisor api

init([]) ->
    Flags = #{strategy => rest_for_one},
    Pool = #{id => telnet_echo_pool,
             start => {telnet_echo_pool, start_link, []}},
    Socket = #{id => telnet_echo_socket,
               start => {telnet_echo_socket, start_link, []}},
    {ok, {Flags, [Pool, Socket]}}.
