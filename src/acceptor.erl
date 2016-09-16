-module(acceptor).

-behaviour(acceptor_loop).

%% public api

-export([spawn_opt/6]).

%% private api

-export([init_it/6]).

%% acceptor_loop api

-export([acceptor_continue/3]).
-export([acceptor_terminate/3]).

-type option() :: {spawn_opt, [proc_lib:spawn_option()]}.

-export_type([option/0]).

-type data() :: #{module => module(),
                  state => term(),
                  socket_module => module(),
                  socket => gen_tcp:socket(),
                  ack => reference()}.

-callback init(SockName, LSock, Args) ->
    {ok, State} | ignore | {error, Reason} when
      SockName :: acceptor_pool:name(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      State :: term(),
      Reason :: term().

-callback enter_loop(PeerName, Sock, State) -> no_return() when
      PeerName :: acceptor_pool:name(),
      Sock :: gen_tcp:socket(),
      State :: term().

-callback terminate(Reason, State) -> any() when
      Reason :: normal | system_limit | inet:posix() | term(),
      State :: term().

%% public api

%% @private
-spec spawn_opt(Mod, SockMod, SockName, LSock, Args, Opts) -> {Pid, Ref} when
      Mod :: module(),
      SockMod :: module(),
      SockName :: acceptor_pool:sockname(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      Opts :: [option()],
      Pid :: pid(),
      Ref :: reference().
spawn_opt(Mod, SockMod, SockName, LSock, Args, Opts) ->
    SRef = make_ref(),
    SArgs = [SRef, Mod, SockMod, SockName, LSock, Args],
    Pid = proc_lib:spawn_opt(?MODULE, init_it, SArgs, spawn_options(Opts)),
    AckRef = monitor(process, Pid),
    _ = Pid ! {ack, SRef, self(), AckRef},
    {Pid, AckRef}.

%% private api

%% @private
init_it(SRef, Mod, SockMod, SockName, LSock, Args) ->
    receive
        {ack, SRef, Parent, AckRef} ->
            try Mod:init(SockName, LSock, Args) of
                Result       ->
                    handle_init(Result, Mod, SockMod, LSock, Parent, AckRef)
            catch
                throw:Result ->
                    handle_init(Result, Mod, SockMod, LSock, Parent, AckRef);
                error:Reason ->
                    exit({Reason, erlang:get_stacktrace()})
            end
    end.

%% acceptor_loop api

%% @private
-spec acceptor_continue({ok, Sock} | {error, Reason}, Parent, Data) ->
    no_return() when
      Sock :: gen_tcp:socket(),
      Reason :: closed | system_limit | inet:posix(),
      Parent :: pid(),
      Data :: data().
acceptor_continue({ok, Sock}, Parent, Data) ->
    #{module := Mod, state := State, ack := AckRef} = Data,
    _ = Parent ! {'ACCEPT', AckRef},
    {ok, PeerName} = inet:peername(Sock),
    case init_socket(Sock, Data) of
        ok              -> Mod:enter_loop(PeerName, Sock, State);
        {error, Reason} -> failure(Reason, Data)
    end;
acceptor_continue({error, Reason}, _, Data) ->
    failure(Reason, Data).

-spec acceptor_terminate(Reason, Parent, Data) -> no_return() when
      Reason :: term(),
      Parent :: pid(),
      Data :: data().
acceptor_terminate(Reason, _, Data) ->
    terminate(Reason, Data).

%% internal

spawn_options(Opts) ->
    case lists:keyfind(spawn_options, 1, Opts) of
        {_, SpawnOpts} -> [link | SpawnOpts];
        false          -> [link]
    end.

handle_init({ok, State}, Mod, SockMod, LSock, Parent, AckRef) ->
    Data = #{module => Mod, state => State, socket_module => SockMod,
             socket => LSock, ack => AckRef},
    % Use another module to accept so can reload this module.
    acceptor_loop:accept(LSock, Parent, ?MODULE, Data);
handle_init(Other, _, _, _, _, _) ->
    handle_init(Other).

handle_init(ignore) ->
    exit(normal);
handle_init({error, Reason}) ->
    exit(Reason);
handle_init(Other) ->
    exit({bad_return_value, Other}).

init_socket(Sock, #{socket_module := SockMod, socket := LSock}) ->
	inet_db:register_socket(Sock, SockMod),
    % As done by prim_inet:accept/2
    OptNames = [active, nodelay, keepalive, delay_send, priority, tos],
    case inet:getopts(LSock, OptNames) of
        {ok, Opts}         -> inet:setopts(Sock, Opts);
        {error, _} = Error -> Error
    end.

failure(einval, #{socket := LSock} = Data) ->
    % LSock could have died
    case erlang:port_info(LSock, connected) of
        {connected, _} -> terminate(einval, Data);
        undefined      -> terminate(normal, Data)
    end;
failure(closed, Data) ->
    terminate(closed, Data);
failure(Reason, #{socket := LSock} = Data) ->
    gen_tcp:close(LSock),
    terminate(Reason, Data).

%% TODO: log abnormal exits
terminate(Reason, #{module := Mod, state := State}) ->
    try
        Mod:terminate(Reason, State)
    catch
        throw:_       -> exit(Reason);
        error:NReason -> exit({NReason, erlang:get_stacktrace()})
    end.
