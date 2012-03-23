-module(udp_exchange).
-include_lib("rabbit_common/include/rabbit.hrl").

-define(EXCHANGE_TYPE_BIN, <<"x-udp">>).

-behaviour(rabbit_exchange_type).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type x-udp"},
		    {mfa,         {rabbit_registry, register,
				   [exchange, ?EXCHANGE_TYPE_BIN, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, create/2, delete/3, add_binding/3,
	 remove_bindings/3, assert_args_equivalence/2]).

description() ->
    [{name, ?EXCHANGE_TYPE_BIN},
     {description, <<"Experimental UDP exchange">>}].

serialise_events() -> false.

%% Called when AMQP clients basic.publish to this exchange.
route(X, Delivery) ->
    ensure_relay_exists(X) ! Delivery,
    [].

%% Called every time this exchange is declared, not just the first.
validate(X) ->
    _ = endpoint_params(X),
    ok.

%% Called just the first time the exchange is declared.
create(transaction, X) ->
    ensure_relay_exists(X),
    ok;
create(none, _X) ->
    ok.

%% Called when we're finally deleted.
delete(transaction, X, _Bs) ->
    shutdown_relay(X),
    ok;
delete(none, _X, _Bs) ->
    ok.

add_binding(Tx, X, B) -> rabbit_exchange_type_topic:add_binding(Tx, X, B).
remove_bindings(Tx, X, Bs) -> rabbit_exchange_type_topic:remove_bindings(Tx, X, Bs).
assert_args_equivalence(X, Args) -> rabbit_exchange:assert_args_equivalence(X, Args).

%%-------------------------------------------------------------------------------------

process_name_for(IpStr, Port) ->
    list_to_atom("udp_exchange_" ++ IpStr ++ "_" ++ integer_to_list(Port)).

endpoint_params(#exchange{name = XName, arguments = Args}) ->
    IpStr = case rabbit_misc:table_lookup(Args, <<"ip">>) of
                {longstr, S} -> binary_to_list(S);
                undefined -> "0.0.0.0";
                _ ->
                    rabbit_misc:protocol_error(precondition_failed,
                                               "Invalid 'ip' argument to ~p exchange (wrong type)",
                                               XName)
            end,
    IpAddr = case inet_parse:address(IpStr) of
                 {ok, A} -> A;
                 _ ->
                     rabbit_misc:protocol_error(precondition_failed,
                                                "Invalid 'ip' argument to ~p exchange (ill-formed)",
                                                XName)
             end,
    Port = case rabbit_misc:table_lookup(Args, <<"port">>) of
               {_, 0} ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "'port' argument to ~p must be nonsero",
                                              XName);
               {_, N} when is_integer(N) -> N;
               undefined ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "Missing 'port' argument to ~p exchange",
                                              XName);
               _ ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "Invalid 'port' argument to ~p exchange (wrong type)",
                                              XName)
           end,
    {IpAddr, Port, process_name_for(IpStr, Port)}.

ensure_relay_exists(X) ->
    {_, _, ProcessName} = endpoint_params(X),
    case whereis(ProcessName) of
        undefined ->
            Pid = spawn(fun () -> relay_main(X) end),
            case catch register(ProcessName, Pid) of
                true ->
                    Pid ! registered,
                    Pid;
                {'EXIT', {badarg, [{erlang, register, _} | _]}} ->
                    Pid ! stop,
                    ensure_relay_exists(X)
            end;
        Pid ->
            Pid
    end.

shutdown_relay(X) ->
    {_, _, ProcessName} = endpoint_params(X),
    case whereis(ProcessName) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            ok
    end.

relay_main(X = #exchange{}) ->
    receive
        stop ->
            ok;
        registered ->
            {IpAddr, Port, _} = endpoint_params(X),
            Opts = [{recbuf, 65536}, binary],
            {ok, Socket} = case IpAddr of
                               {0,0,0,0} -> gen_udp:open(Port, Opts);
                               _ -> gen_udp:open(Port, [{ip, IpAddr} | Opts])
                           end,
            relay_mainloop(X, Socket)
    end.

%% We behave like a topic exchange.
deliver(X, Delivery) ->
    QueueNames = rabbit_exchange_type_topic:route(X, Delivery),
    Queues = rabbit_amqqueue:lookup(QueueNames),
    {routed, _} = rabbit_amqqueue:deliver(Queues, Delivery),
    ok.

truncate_bin(Limit, B) ->
    case B of
        <<X:Limit/binary, _/binary>> -> X;
        _ -> B
    end.

udp_delivery(XName, {A, B, C, D}, Port, Body) ->
    IpStr = list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])),
    Headers = [{<<"source_ip">>, longstr, IpStr},
               {<<"source_port">>, short, Port}],
    RoutingKey = truncate_bin(255, list_to_binary(["ipv4",
                                                   ".", IpStr,
                                                   ".", integer_to_list(Port),
                                                   ".", Body])),
    rabbit_basic:delivery(false, false,
                          rabbit_basic:message(XName, RoutingKey, [{headers, Headers}], Body),
			  undefined).

analyze_delivery(#delivery{message =
                               #basic_message{routing_keys = [RoutingKey],
                                              content =
                                                  #content{payload_fragments_rev = PayloadRev}}}) ->
    <<"ipv4.", Rest/binary>> = RoutingKey,
    [AStr, BStr, CStr, DStr, PortStr | _] = binary:split(Rest, <<".">>, [global]),
    A = list_to_integer(binary_to_list(AStr)),
    B = list_to_integer(binary_to_list(BStr)),
    C = list_to_integer(binary_to_list(CStr)),
    D = list_to_integer(binary_to_list(DStr)),
    Port = list_to_integer(binary_to_list(PortStr)),
    {{A, B, C, D}, Port, lists:reverse(PayloadRev)}.

relay_mainloop(X, Socket) ->
    receive
        stop ->
            ok = gen_udp:close(Socket);
        Delivery = #delivery{} ->
            case catch analyze_delivery(Delivery) of
                {TargetIp, TargetPort, Packet} ->
                    ok = gen_udp:send(Socket, TargetIp, TargetPort, Packet);
                {'EXIT', _} ->
                    %% Discard messages we can't shoehorn into UDP.
                    RKs = Delivery#delivery.message#basic_message.routing_keys,
                    error_logger:warning_report({?MODULE, analyze_delivery, failed,
                                                 [{exchange, X#exchange.name},
                                                  {routing_keys, RKs}]}),
                    ok
            end,
            relay_mainloop(X, Socket);
        {udp, _Socket, SourceIp, SourcePort, Packet} ->
            ok = deliver(X, udp_delivery(X#exchange.name, SourceIp, SourcePort, Packet)),
            relay_mainloop(X, Socket);
        Other ->
            exit({udp_exchange, relay, bad_message, Other})
    end.
