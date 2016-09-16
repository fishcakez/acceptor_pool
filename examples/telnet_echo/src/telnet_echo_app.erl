-module(telnet_echo_app).

-behaviour(application).

%% application api

-export([start/2,
         stop/1]).

%% application api

start(_, _) ->
    telnet_echo_sup:start_link().

stop(_State) ->
    ok.
