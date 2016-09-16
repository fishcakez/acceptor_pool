%% @private
-module(acceptor_loop).

-export([accept/5]).
-export([await/5]).

-callback acceptor_continue({ok, Sock} | {error, Reason}, Parent, Misc) ->
    no_return() when
      Sock :: gen_tcp:socket(),
      Reason :: timeout | closed | system_limit | inet:posix(),
      Parent :: pid(),
      Misc :: term().

-callback acceptor_terminate(Reason, Parent, Misc) -> no_return() when
      Reason :: term(),
      Parent :: pid(),
      Misc :: term().

-spec accept(LSock, TimeoutOrHib, Parent, Mod, Misc) -> no_return() when
      LSock :: gen_tcp:socket(),
      TimeoutOrHib :: timeout() | hibernate,
      Parent :: pid(),
      Mod :: module(),
      Misc :: term().
accept(LSock, hibernate, Parent, Mod, Misc) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, InetRef} ->
            Args = [LSock, InetRef, Parent, Mod, Misc],
            proc_lib:hibernate(?MODULE, await, Args);
        {error, _} = Error ->
            Mod:acceptor_continue(Error, Parent, Misc)
    end;
accept(LSock, Timeout, Parent, Mod, Misc) ->
    accept_timeout(LSock, Timeout, Parent, Mod, Misc).

-spec await(LSock, InetRef, Parent, Mod, Misc) -> no_return() when
      LSock :: gen_tcp:socket(),
      InetRef :: term(),
      Parent :: pid(),
      Mod :: module(),
      Misc :: term().
await(LSock, InetRef, Parent, Mod, Misc) ->
    receive
        {inet_async, LSock, InetRef, Result} ->
            Mod:acceptor_continue(Result, Parent, Misc);
        {'EXIT', Parent, Reason} ->
            Mod:acceptor_terminate(Reason, Parent, Misc)
    end.

%% internal

accept_timeout(LSock, infinity, Parent, Mod, Misc) ->
    accept_timeout(LSock, -1, Parent, Mod, Misc);
accept_timeout(LSock, Timeout, Parent, Mod, Misc) ->
    case prim_inet:async_accept(LSock, Timeout) of
        {ok, InetRef}      -> await(LSock, InetRef, Parent, Mod, Misc);
        {error, _} = Error -> Mod:acceptor_continue(Error, Parent, Misc)
    end.
