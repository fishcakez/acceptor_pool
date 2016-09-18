-module(telnet_echo_conn).

-behaviour(acceptor).
-behaviour(gen_server).

%% acceptor api

-export([acceptor_init/3,
         acceptor_continue/3,
         acceptor_terminate/2]).

%% gen_server api

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

acceptor_init(_SockName, LSocket, []) ->
    % monitor listen socket to gracefully close when it closes
    MRef = monitor(port, LSocket),
    {ok, MRef}.

acceptor_continue(_PeerName, Socket, MRef) ->
    gen_server:enter_loop(?MODULE, [], {Socket, MRef}).

acceptor_terminate(Reason, _) ->
    % Something when wrong. Either the acceptor_pool is terminating or the
    % accept failed.
    exit(Reason).

%% gen_server api

init(_) ->
    {stop, acceptor}.

handle_call(Req, _, State) ->
    {stop, {bad_call, Req}, State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({tcp, Socket, Data}, {Socket, _} = State) ->
    case gen_tcp:send(Socket, Data) of
        ok ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info({tcp_error, Socket, Reason}, {Socket, _} = State) ->
    {stop, Reason, State};
handle_info({tcp_closed, Socket}, {Socket, _} = State) ->
    {stop, normal, State};
handle_info({'DOWN', MRef, port, _, _}, {Socket, MRef} = State) ->
    %% Listen socket closed, receive all pending data then stop. In more
    %% advanced protocols will likely be able to do better.
    error_logger:info_msg("Gracefully closing ~p~n", [Socket]),
    {stop, flush_socket(Socket), State};
handle_info(_, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

%% internal

flush_socket(Socket) ->
    receive
        {tcp, Socket, Data}         -> flush_send(Socket, Data);
        {tcp_error, Socket, Reason} -> Reason;
        {tcp_closed, Socket}        -> normal
    after
        0                           -> normal
    end.

flush_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok              -> flush_recv(Socket);
        {error, closed} -> normal;
        {error, Reason} -> Reason
    end.

flush_recv(Socket) ->
    case gen_tcp:recv(Socket, 0, 0) of
        {ok, Data}       -> flush_send(Socket, Data);
        {error, timeout} -> normal;
        {error, closed}  -> normal;
        {error, Reason}  -> Reason
    end.
