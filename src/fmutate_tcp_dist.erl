%% Keeps the loopback distribution socket from accepting connections until
%% FMutate has installed net_kernel's non-empty allow list and per-node cookies.
%%
%% net_kernel opens the listen socket during init, before allow/1 can run. Its
%% transport acceptor is replaceable, though: this module delegates inet_tcp
%% distribution and parks that acceptor behind an explicit gate. FMutate.Dist
%% closes the gate before Node.start/2 and opens it after configuration.
-module(fmutate_tcp_dist).

-export([listen/1, listen/2, accept/1, accept_connection/5,
         setup/5, close/1, select/1, address/0, is_node_name/1,
         setopts/2, getopts/2, prepare/0, activate/0, configured/0]).

-define(GATE, fmutate_tcp_dist_accept_gate).
-define(ACTIVE, {?MODULE, active}).

listen(Name) -> inet_tcp_dist:listen(Name).
listen(Name, Host) -> inet_tcp_dist:listen(Name, Host).

accept(Listen) ->
    Kernel = self(),
    spawn_opt(fun() -> accept_gate(Kernel, Listen) end,
              [link, {priority, max}]).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    inet_tcp_dist:accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    inet_tcp_dist:setup(Node, Type, MyNode, LongOrShortNames, SetupTime).

close(Socket) -> inet_tcp_dist:close(Socket).
select(Node) -> inet_tcp_dist:select(Node).
address() -> inet_tcp_dist:address().
is_node_name(Node) -> inet_tcp_dist:is_node_name(Node).
setopts(Socket, Options) -> inet_tcp_dist:setopts(Socket, Options).
getopts(Socket, Options) -> inet_tcp_dist:getopts(Socket, Options).

prepare() ->
    persistent_term:put(?ACTIVE, false),
    case whereis(?GATE) of
        undefined -> ok;
        Pid -> Pid ! stop
    end,
    ok.

activate() ->
    persistent_term:put(?ACTIVE, true),
    case whereis(?GATE) of
        undefined -> ok;
        Pid -> Pid ! activate
    end,
    ok.

configured() ->
    case init:get_argument(proto_dist) of
        {ok, [["fmutate_tcp"]]} -> true;
        _ -> false
    end.

accept_gate(Kernel, Listen) ->
    true = register(?GATE, self()),
    case persistent_term:get(?ACTIVE, false) of
        true -> accept_loop(Kernel, Listen);
        false ->
            receive
                activate -> accept_loop(Kernel, Listen);
                stop -> exit(normal)
            end
    end.

accept_loop(Kernel, Listen) ->
    unregister(?GATE),
    inet_tcp_dist:accept_loop(inet_tcp, Kernel, Listen).
