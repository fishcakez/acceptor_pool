-module(acceptor_pool).

-behaviour(gen_server).

%% public api

-export([start_link/2,
         start_link/3,
         attach_socket/3,
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

-type pool_flags() :: #{}.

-type acceptor_spec() :: #{id := term(),
                           start := {module(), any(), [acceptor:option()]},
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
                type :: worker | supervisor,
                modules :: [module()] | dynamic,
                sockets = #{} :: #{reference() =>
                                   {module(), name(), gen_tcp:socket()}},
                acceptors = #{} :: #{pid() =>
                                     {reference(), name(), reference()}},
                conns = #{} :: #{pid() => {name(), name(), reference()}}}).

-callback init(Args) -> {ok, PoolFlags, [AcceptorSpec, ...]} | ignore when
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

-spec attach_socket(Pool, Sock, Acceptors) -> {ok, Ref} | {error, Reason} when
      Pool :: pool(),
      Sock :: gen_tcp:socket(),
      Acceptors :: pos_integer(),
      Ref :: reference(),
      Reason :: inet:posix().
attach_socket(Pool, Sock, Acceptors)
  when is_port(Sock), is_integer(Acceptors), Acceptors > 0 ->
    gen_server:call(Pool, {attach_socket, Sock, Acceptors}, infinity).

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
      Counts :: [{spec, active | workers | supervisors, non_neg_integer()}].
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

handle_call({attach_socket, Sock, NumAcceptors}, _, State) ->
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

handle_info({'EXIT', Conn, _}, State) ->
    handle_exit(Conn, State);
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
handle_info({'CANCEL', Pid, AcceptRef}, State) ->
    #state{acceptors=Acceptors} = State,
    case Acceptors of
        #{Pid := {SockRef, SockName, AcceptRef}} ->
            NAcceptors = start_acceptor(SockRef, Acceptors, State),
            PidInfo = {undefined, SockName, AcceptRef},
            {noreply, State#state{acceptors=NAcceptors#{Pid := PidInfo}}};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', SockRef, port, _, _}, #state{sockets=Sockets} = State) ->
    {noreply, State#state{sockets=maps:remove(SockRef, Sockets)}};
handle_info(Msg, #state{name=Name} = State) ->
    error_logger:error_msg("~p received unexpected message: ~p~n", [Name, Msg]),
    {noreply, State}.

code_change(_, State, _) ->
    % TODO: Support supervisor style reconfiguration with code change
    {ok, State}.

format_status(terminate, [_, State]) ->
    State;
format_status(_, [_, #state{mod=Mod} = State]) ->
    [{data, [{"State", State}]}, {supervisor, [{"Callback", Mod}]}].

terminate(_, #state{conns=Conns}) ->
    _ = [exit(Conn, shutdown) || {Conn, _} <- maps:to_list(Conns)],
    terminate(Conns).

%% internal

terminate(Conns) ->
    % TODO: send supervisor_report for abnormal exit
    % TODO: shutdown like a supervisor
    Conn = receive {'EXIT', Pid, _} -> Pid end,
    case maps:remove(Conn, Conns) of
        NConns when map_size(NConns) == 0 ->
            ok;
        NConns ->
            terminate(NConns)
    end.

%% TODO: Handle pool flags and acceptor specs
init(Name, Mod, Args,
     {ok, {#{}, [#{id := Id, start := {AMod, _, _} = Start} = Spec]}}) ->
    Type = maps:get(type, Spec, worker),
    Modules = maps:get(modules, Spec, [AMod]),
    State = #state{name=Name, mod=Mod, args=Args, id=Id, start=Start, type=Type,
                   modules=Modules},
    {ok, State};
init(_, _, _, ignore) ->
    ignore;
init(_, Mod, _, Other) ->
    {stop, {bad_return, {Mod, init, Other}}}.

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

handle_exit(Pid, #state{conns=Conns} = State) ->
    case maps:take(Pid, Conns) of
        {_, NConns} ->
            {noreply, State#state{conns=NConns}};
        error ->
            acceptor_exit(Pid, State)
    end.

acceptor_exit(Pid, #state{acceptors=Acceptors} = State) ->
    case maps:take(Pid, Acceptors) of
        {{SockRef, _, _}, NAcceptors} ->
            NAcceptors2 = start_acceptor(SockRef, NAcceptors, State),
            {noreply, State#state{acceptors=NAcceptors2}};
        error ->
            {noreply, State}
    end.
