%% @private
-module(acceptor_loop).

-export([accept/4]).

-callback acceptor_continue({ok, Sock} | {error, Reason}, Parent, Misc) ->
    no_return() when
      Sock :: gen_tcp:socket(),
      Reason :: closed | system_limit | inet:posix(),
      Parent :: pid(),
      Misc :: term().

-callback acceptor_terminate(Reason, Parent, Misc) -> no_return() when
      Reason :: term(),
      Parent :: pid(),
      Misc :: term().

-spec accept(LSock, Parent, Mod, Misc) -> no_return() when
      LSock :: gen_tcp:socket(),
      Parent :: pid(),
      Mod :: module(),
      Misc :: term().
accept(LSock, Parent, Mod, Misc) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, InetRef}      -> await(LSock, InetRef, Parent, Mod, Misc);
        {error, _} = Error -> Mod:acceptor_continue(Error, Parent, Misc)
    end.

%% internal

await(LSock, InetRef, Parent, Mod, Misc) ->
    receive
        {inet_async, LSock, InetRef, Result} ->
            Mod:acceptor_continue(Result, Parent, Misc);
        {'EXIT', Parent, Reason} ->
            Mod:acceptor_terminate(Reason, Parent, Misc)
    end.
