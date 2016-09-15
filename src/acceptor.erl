-module(acceptor).

%% public api

-export([spawn_opt/5]).

%% private api

-export([init_it/6]).

-type option() :: {spawn_opt, [proc_lib:spawn_option()]} |
                  {accept_timeout, timeout()}.

-export_type([option/0]).

-callback init(SockName, LSock, Args) ->
    {ok, State} | ignore | {error, Reason} when
      SockName :: acceptor_pool:sockname(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      State :: term(),
      Reason :: term().

-callback enter_loop(Sock, State) -> no_return() when
      Sock :: gen_tcp:socket(),
      State :: term().

-callback terminate(Reason, State) -> any() when
      Reason :: normal | system_limit | inet:posix() | term(),
      State :: term().

%% public api

%% @private
-spec spawn_opt(Mod, SockName, LSock, Args, Opts) -> {Pid, Ref} when
      Mod :: module(),
      SockName :: acceptor_pool:sockname(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      Opts :: [option()],
      Pid :: pid(),
      Ref :: reference().
spawn_opt(Mod, SockName, LSock, Args, Opts) ->
    SRef = make_ref(),
    SArgs = [SRef, Mod, SockName, LSock, Args, Opts],
    Pid = proc_lib:spawn_opt(?MODULE, init_it, SArgs, spawn_options(Opts)),
    ARef = monitor(process, Pid),
    _ = Pid ! {ack, SRef, self(), ARef},
    {Pid, ARef}.

%% private api

%% @private
init_it(SRef, Mod, SockName, LSock, Args, Opts) ->
    receive
        {ack, SRef, Starter, ARef} ->
            try Mod:init(SockName, LSock, Args) of
                Result ->
                    handle_init(Result, Mod, LSock, Starter, ARef, Opts)
            catch
                throw:Result ->
                    handle_init(Result, Mod, LSock, Starter, ARef, Opts);
                error:Reason ->
                    exit({Reason, erlang:get_stacktrace()})
            end
    end.

%% internal

spawn_options(Opts) ->
    case lists:keyfind(spawn_options, 1, Opts) of
        {_, SpawnOpts} -> [link | SpawnOpts];
        false          -> [link]
    end.

handle_init({ok, State}, Mod, LSock, Starter, ARef, Opts) ->
    % Custom tcp_module or bad timeout could cause exception
    try gen_tcp:accept(LSock, accept_timeout(Opts)) of
        {ok, Sock} ->
            _ = Starter ! {'ACCEPT', ARef},
            Mod:enter_loop(Sock, State);
        {error, Reason} when Reason == timeout; Reason == closed ->
            terminate(Mod, normal, State);
        {error, Reason} ->
            gen_tcp:close(LSock),
            terminate(Mod, Reason, State)
    catch
        exit:Reason ->
            terminate(Mod, Reason, State);
        error:Reason ->
            terminate(Mod, {Reason, erlang:get_stacktrace()}, State);
        throw:Reason ->
            NReason = {{nocatch, Reason}, erlang:get_stacktrace()},
            terminate(Mod, NReason, State)
    end;
handle_init(Other, _, _, _, _, _) ->
    handle_init(Other).

handle_init(ignore) ->
    exit(normal);
handle_init({error, Reason}) ->
    exit(Reason);
handle_init(Other) ->
    exit({bad_return_value, Other}).

accept_timeout(Opts) ->
    case lists:keyfind(accept_timeout, 1, Opts) of
        {_, Timeout} -> Timeout;
        false        -> infinity
    end.

%% TODO: log abnormal exits
terminate(Mod, Reason, State) ->
    try
        Mod:terminate(Reason, State)
    catch
        throw:_ ->
            exit(Reason);
        error:NReason ->
            exit({NReason, erlang:get_stacktrace()})
    end.
