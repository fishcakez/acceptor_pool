-module(acceptor_pool).

-behaviour(gen_server).

%% public api

-export([start_link/2,
         start_link/3,
         accept_socket/3,
         which_sockets/1]).

%% supervisor api

-export([which_children/1,
         count_children/1]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([format_status/2]).
-export([terminate/2]).

-type pool() :: pid() | atom() | {atom(), node()} | {via, module(), any()} |
                {global, any()}.

-type pool_flags() :: #{intensity => non_neg_integer(),
                        period => pos_integer()}.

-type acceptor_spec() :: #{id := term(),
                           start := {module(), any(), [acceptor:option()]},
                           restart => permanent | transient | temporary,
                           shutdown => timeout() | brutal_kill,
                           grace => timeout(),
                           type => worker | supervisor,
                           modules => [module()] | dynamic}.

-type name() ::
    {inet:ip_address(), inet:port_number()} | inet:returned_non_ip_address().

-export_type([pool/0,
              pool_flags/0,
              acceptor_spec/0,
              name/0]).

-record(state, {name,
                mod :: module(),
                args :: any(),
                id :: term(),
                start :: {module(), any(), [acceptor:option()]},
                restart :: permanent | transient | temporary,
                shutdown :: timeout() | brutal_kill,
                grace :: timeout(),
                type :: worker | supervisor,
                modules :: [module()] | dynamic,
                intensity :: non_neg_integer(),
                period :: pos_integer(),
                restarts = queue:new() :: queue:queue(integer()),
                sockets = #{} :: #{reference() =>
                                   {module(), name(), gen_tcp:socket()}},
                acceptors = #{} :: #{pid() =>
                                     {reference(), name(), reference()}},
                conns = #{} :: #{pid() => {name(), name(), reference()}}}).

-callback init(Args) -> {ok, {PoolFlags, [AcceptorSpec, ...]}} | ignore when
      Args :: any(),
      PoolFlags :: pool_flags(),
      AcceptorSpec :: acceptor_spec().

%% public api

-spec start_link(Module, Args) -> {ok, Pid} | ignore | {error, Reason} when
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Module, Args) ->
    gen_server:start_link(?MODULE, {self, Module, Args}, []).

-spec start_link(Name, Module, Args) ->
    {ok, Pid} | ignore | {error, Reason} when
      Name :: {local, atom()} | {via, module, any()} | {global, any()},
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Name, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Name, Module, Args}, []).

-spec accept_socket(Pool, Sock, Acceptors) -> {ok, Ref} | {error, Reason} when
      Pool :: pool(),
      Sock :: gen_tcp:socket(),
      Acceptors :: pos_integer(),
      Ref :: reference(),
      Reason :: inet:posix().
accept_socket(Pool, Sock, Acceptors)
  when is_port(Sock), is_integer(Acceptors), Acceptors > 0 ->
    gen_server:call(Pool, {accept_socket, Sock, Acceptors}, infinity).

-spec which_sockets(Pool) -> [{SockModule, SockName, Sock, Ref}] when
      Pool :: pool(),
      SockModule :: module(),
      SockName :: name(),
      Sock :: gen_tcp:socket(),
      Ref :: reference().
which_sockets(Pool) ->
    gen_server:call(Pool, which_sockets, infinity).

-spec which_children(Pool) -> [{Id, Child, Type, Modules}] when
      Pool :: pool(),
      Id :: {term(), name(), name(), reference()},
      Child :: pid(),
      Type :: worker | supervisor,
      Modules :: [module()] | dynamic.
which_children(Pool) ->
    gen_server:call(Pool, which_children, infinity).

-spec count_children(Pool) -> Counts when
      Pool :: pool(),
      Counts :: [{spec | active | workers | supervisors, non_neg_integer()}].
count_children(Pool) ->
    gen_server:call(Pool, count_children, infinity).

%% gen_server api

%% @private
init({self, Mod, Args}) ->
    init({self(), Mod, Args});
init({Name, Mod, Args}) ->
    _ = process_flag(trap_exit, true),
    try Mod:init(Args) of
        Res ->
            init(Name, Mod, Args, Res)
    catch
        throw:Res ->
            init(Name, Mod, Args, Res)
    end.

handle_call({accept_socket, Sock, NumAcceptors}, _, State) ->
    SockRef = monitor(port, Sock),
    case socket_info(Sock) of
        {ok, SockInfo} ->
            NState = start_acceptors(SockRef, SockInfo, NumAcceptors, State),
            {reply, {ok, SockRef}, NState};
        {error, _} = Error ->
            demonitor(SockRef, [flush]),
            {reply, Error, State}
    end;
handle_call(which_sockets, _, #state{sockets=Sockets} = State) ->
    Reply = [{SockMod, SockName, Sock, SockRef} ||
             {SockRef, {SockMod, SockName, Sock}} <- maps:to_list(Sockets)],
    {reply, Reply, State};
handle_call(which_children, _, State) ->
    #state{conns=Conns, id=Id, type=Type, modules=Modules} = State,
    Children = [{{Id, PeerName, SockName, Ref}, Pid, Type, Modules} ||
                {Pid, {PeerName, SockName, Ref}} <- maps:to_list(Conns)],
    {reply, Children, State};
handle_call(count_children, _, State) ->
    {reply, count(State), State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({'EXIT', Conn, Reason}, State) ->
    handle_exit(Conn, Reason, State);
handle_info({'ACCEPT', Pid, AcceptRef, PeerName}, State) ->
    #state{acceptors=Acceptors, conns=Conns} = State,
    case maps:take(Pid, Acceptors) of
        {{SockRef, SockName, AcceptRef}, NAcceptors} ->
            NAcceptors2 = start_acceptor(SockRef, NAcceptors, State),
            NConns = Conns#{Pid => {PeerName, SockName, AcceptRef}},
            {noreply, State#state{acceptors=NAcceptors2, conns=NConns}};
        error ->
            {noreply, State}
    end;
handle_info({'CANCEL', Pid, AcceptRef}, #state{acceptors=Acceptors} = State) ->
    case Acceptors of
        #{Pid := {SockRef, SockName, AcceptRef}} ->
            NAcceptors = start_acceptor(SockRef, Acceptors, State),
            PidInfo = {undefined, SockName, AcceptRef},
            {noreply, State#state{acceptors=NAcceptors#{Pid := PidInfo}}};
        _ ->
            {noreply, State}
    end;
handle_info({'IGNORE', Pid, AcceptRef}, #state{acceptors=Acceptors} = State) ->
    case maps:take(Pid, Acceptors) of
        {{SockRef, _, AcceptRef}, NAcceptors} ->
            NAcceptors2 = start_acceptor(SockRef, NAcceptors, State),
            {noreply, State#state{acceptors=NAcceptors2}};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', SockRef, port, _, _}, #state{sockets=Sockets} = State) ->
    {noreply, State#state{sockets=maps:remove(SockRef, Sockets)}};
handle_info(Msg, #state{name=Name} = State) ->
    error_logger:error_msg("~p received unexpected message: ~p~n", [Name, Msg]),
    {noreply, State}.

code_change(_, #state{mod=Mod, args=Args} = State, _) ->
    try Mod:init(Args) of
        Result       -> change_init(Result, State)
    catch
        throw:Result -> change_init(Result, State)
    end.

format_status(terminate, [_, State]) ->
    State;
format_status(_, [_, #state{mod=Mod} = State]) ->
    [{data, [{"State", State}]}, {supervisor, [{"Callback", Mod}]}].

terminate(_, #state{conns=Conns, acceptors=Acceptors, grace=Grace,
                    shutdown=Shutdown}) ->
    Pids = maps:keys(Acceptors) ++ maps:keys(Conns),
    MRefs = maps:from_list([{monitor(process, Pid), Pid} || Pid <- Pids]),
    case Grace of
        infinity ->
            await_down(make_ref(), MRefs);
        _ when Shutdown /= brutal_kill ->
            Timer = erlang:start_timer(Grace, self(), {shutdown, Shutdown}),
            await_down(Timer, MRefs);
        _ when Shutdown == brutal_kill ->
            Timer = erlang:start_timer(Grace, self(), brutal_kill),
            await_down(Timer, MRefs)
    end.

%% internal

init(Name, Mod, Args,
     {ok,
      {#{} = Flags, [#{id := Id, start := {AMod, _, _} = Start} = Spec]}}) ->
    % Same defaults as supervisor
    Intensity = maps:get(intensity, Flags, 1),
    Period = maps:get(period, Flags, 5),
    Restart = maps:get(restart, Spec, temporary),
    Type = maps:get(type, Spec, worker),
    Shutdown = maps:get(shutdown, Spec, shutdown_default(Type)),
    Grace = maps:get(grace, Spec, 0),
    Modules = maps:get(modules, Spec, [AMod]),
    State = #state{name=Name, mod=Mod, args=Args, id=Id, start=Start,
                   restart=Restart, shutdown=Shutdown, grace=Grace, type=Type,
                   modules=Modules, intensity=Intensity, period=Period},
    {ok, State};
init(_, _, _, ignore) ->
    ignore;
init(_, Mod, _, Other) ->
    {stop, {bad_return, {Mod, init, Other}}}.

shutdown_default(worker)     -> 5000;
shutdown_default(supervisor) -> infinity.

count(#state{conns=Conns, acceptors=Acceptors, type=Type}) ->
    Active = maps:size(Conns),
    Size = Active + maps:size(Acceptors),
    case Type of
        worker ->
            [{specs, 1}, {active, Active}, {supervisors, 0}, {workers, Size}];
        supervisor ->
            [{specs, 1}, {active, Active}, {supervisors, Size}, {workers, 0}]
    end.

socket_info(Sock) ->
    case inet_db:lookup_socket(Sock) of
        {ok, SockMod}      -> socket_info(SockMod, Sock);
        {error, _} = Error -> Error
    end.

socket_info(SockMod, Sock) ->
    case inet:sockname(Sock) of
        {ok, SockName}     -> {ok, {SockMod, SockName, Sock}};
        {error, _} = Error -> Error
    end.

start_acceptors(SockRef, SockInfo, NumAcceptors, State) ->
    #state{sockets=Sockets, acceptors=Acceptors} = State,
    NState = State#state{sockets=Sockets#{SockRef => SockInfo}},
    NAcceptors = start_loop(SockRef, NumAcceptors, Acceptors, NState),
    NState#state{acceptors=NAcceptors}.

start_loop(_, 0, Acceptors, _) ->
    Acceptors;
start_loop(SockRef, N, Acceptors, State) ->
    start_loop(SockRef, N-1, start_acceptor(SockRef, Acceptors, State), State).

start_acceptor(SockRef, Acceptors,
               #state{sockets=Sockets, start={Mod, Args, Opts}}) ->
    case Sockets of
        #{SockRef := {SockMod, SockName, Sock}} ->
            {Pid, AcceptRef} =
                acceptor:spawn_opt(Mod, SockMod, SockName, Sock, Args, Opts),
            Acceptors#{Pid => {SockRef, SockName, AcceptRef}};
        _ ->
            Acceptors
    end.

handle_exit(Pid, Reason, #state{conns=Conns} = State) ->
    case maps:take(Pid, Conns) of
        {_, NConns} ->
            child_exit(Reason, State#state{conns=NConns});
        error ->
            acceptor_exit(Pid, Reason, State)
    end.

% TODO: Send supervisor_reports like a supervisor
child_exit(_, #state{restart=temporary} = State) ->
    {noreply, State};
child_exit(normal, #state{restart=transient} = State) ->
    {noreply, State};
child_exit(shutdown, #state{restart=transient} = State) ->
    {noreply, State};
child_exit({shutdown, _}, #state{restart=transient} = State) ->
    {noreply, State};
child_exit(_, State) ->
    case add_restart(State) of
        {ok, NState}   -> {noreply, NState};
        {stop, NState} -> {stop, shutdown, NState}
    end.

acceptor_exit(Pid, Reason, #state{acceptors=Acceptors} = State) ->
    case maps:take(Pid, Acceptors) of
        {{SockRef, _, _}, NAcceptors} when SockRef =/= undefined ->
            restart_acceptor(SockRef, NAcceptors, State);
        {{undefined, _, _}, NAcceptors} ->
            % Received 'CANCEL' due to accept timeout or error. If accept error
            % we are waiting for listen socket 'DOWN' to cancel accepting and
            % don't want accept errors to bring down pool. The acceptor will
            % have sent exit signal to listen socket, hopefully isolating the
            % pool from a bad listen socket. With permanent restart or
            % acceptor_terminate/2 crash the max intensity can still be reached.
            child_exit(Reason, State#state{acceptors=NAcceptors});
        error ->
            {noreply, State}
    end.

restart_acceptor(SockRef, Acceptors, State) ->
    case add_restart(State) of
        {ok, NState} ->
            NAcceptors = start_acceptor(SockRef, Acceptors, NState),
            {noreply, NState#state{acceptors=NAcceptors}};
        {stop, NState} ->
            {stop, shutdown, NState#state{acceptors=Acceptors}}
    end.

add_restart(State) ->
    #state{intensity=Intensity, period=Period, restarts=Restarts} = State,
    Now = erlang:monotonic_time(1),
    NRestarts = drop_restarts(Now - Period, queue:in(Now, Restarts)),
    NState = State#state{restarts=NRestarts},
    case queue:len(NRestarts) of
        Len when Len =< Intensity -> {ok, NState};
        Len when Len > Intensity  -> {stop, NState}
    end.

drop_restarts(Stale, Restarts) ->
    % Just inserted Now and Now > Stale so get/1 and drop/1 always succeed
    case queue:get(Restarts) of
        Time when Time >= Stale -> Restarts;
        Time when Time < Stale  -> drop_restarts(Stale, queue:drop(Restarts))
    end.

change_init(Result, State) ->
    #state{name=Name, mod=Mod, args=Args, restarts=Restarts, sockets=Sockets,
           acceptors=Acceptors, conns=Conns} = State,
    case init(Name, Mod, Args, Result) of
        {ok, NState} ->
            {ok, NState#state{restarts=Restarts, sockets=Sockets,
                              acceptors=Acceptors, conns=Conns}};
        ignore ->
            {ok, State};
        {stop, Reason} ->
            {error, Reason}
    end.

await_down(Timer, MRefs) when map_size(MRefs) > 0 ->
    receive
        {'DOWN', MRef, _, _, _} ->
            await_down(Timer, maps:remove(MRef, MRefs));
        {timeout, Timer, brutal_kill}  ->
            exits(kill, MRefs),
            await_down(Timer, MRefs);
        {timeout, Timer, {shutdown, infinity}} ->
            exits(shutdown, MRefs),
            await_down(Timer, MRefs);
        {timeout, Timer, {shutdown, Timeout}} ->
            exits(shutdown, MRefs),
            NTimer = erlang:start_timer(Timeout, self(), brutal_kill),
            await_down(NTimer, MRefs);
        _ ->
            await_down(Timer, MRefs)
    end;
await_down(_, _) ->
    ok.

exits(Reason, MRefs) ->
    _ = [exit(Pid, Reason) || Pid <- maps:values(MRefs)],
    ok.
