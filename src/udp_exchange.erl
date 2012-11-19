%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
-module(udp_exchange).
-include_lib("rabbit_common/include/rabbit.hrl").
-include("udp_exchange.hrl").

-define(EXCHANGE_TYPE_BIN, <<"x-udp">>).

-behaviour(rabbit_exchange_type).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type x-udp"},
		    {mfa,         {rabbit_registry, register,
				   [exchange, ?EXCHANGE_TYPE_BIN, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, create/2, delete/3, policy_changed/3, add_binding/3,
	 remove_bindings/3, assert_args_equivalence/2]).

-export([truncate_bin/2]). %% utility

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

policy_changed(_Tx, _X1, _X2) -> ok.

add_binding(Tx, X, B) -> rabbit_exchange_type_topic:add_binding(Tx, X, B).
remove_bindings(Tx, X, Bs) -> rabbit_exchange_type_topic:remove_bindings(Tx, X, Bs).
assert_args_equivalence(X, Args) -> rabbit_exchange:assert_args_equivalence(X, Args).

%%-------------------------------------------------------------------------------------

process_name_for(IpStr, Port) ->
    list_to_atom("udp_exchange_" ++ IpStr ++ "_" ++ integer_to_list(Port)).

endpoint_params(X = #exchange{name = XName, arguments = Args}) ->
    IpStr = case rabbit_misc:table_lookup(Args, <<"ip">>) of
                {longstr, S} -> binary_to_list(S);
                undefined -> "0.0.0.0";
                _ ->
                    rabbit_misc:protocol_error(precondition_failed,
                                               "Invalid 'ip' argument to ~s (wrong type)",
                                               [rabbit_misc:rs(XName)])
            end,
    IpAddr = case inet_parse:address(IpStr) of
                 {ok, A} -> A;
                 _ ->
                     rabbit_misc:protocol_error(precondition_failed,
                                                "Invalid 'ip' argument to ~s (ill-formed)",
                                                [rabbit_misc:rs(XName)])
             end,
    Port = case rabbit_misc:table_lookup(Args, <<"port">>) of
               {_, 0} ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "'port' argument to ~s must be nonsero",
                                              [rabbit_misc:rs(XName)]);
               {_, N} when is_integer(N) ->
                   if
                       N < 0 -> N + 65536; %% stupid signed short encoding in AMQP!
                       true -> N
                   end;
               {longstr, PortStr} ->
                   %% Gross. We support this because the RabbitMQ
                   %% management console doesn't yet permit selection
                   %% of argument types other than strings. This
                   %% should be removed as soon as possible. (Also,
                   %% we're not catching possible badargs.)
                   list_to_integer(binary_to_list(PortStr));
               undefined ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "Missing 'port' argument to ~s",
                                              [rabbit_misc:rs(XName)]);
               _ ->
                   rabbit_misc:protocol_error(precondition_failed,
                                              "Invalid 'port' argument to ~s (wrong type)",
                                              [rabbit_misc:rs(XName)])
           end,
    PacketModule =
        case rabbit_misc:table_lookup(Args, <<"format">>) of
            {longstr, FormatBin} ->
                FormatStr = binary_to_list(FormatBin),
                ModuleStr = "udp_exchange_"++FormatStr++"_packet",
                case code:where_is_file(ModuleStr ++ ".beam") of
                    non_existing ->
                        rabbit_misc:protocol_error
                          (precondition_failed,
                           "Invalid 'format' argument to ~s (module ~s not found)",
                           [rabbit_misc:rs(XName), ModuleStr]);
                    _ ->
                        list_to_atom(ModuleStr)
                end;
            undefined ->
                udp_exchange_raw_packet;
            _ ->
                rabbit_misc:protocol_error(precondition_failed,
                                           "Invalid 'format' argument to ~s (wrong type)",
                                           [rabbit_misc:rs(XName)])
        end,
    PacketConfig = PacketModule:configure(X),
    #params{exchange_def = X,
            ip_addr = IpAddr,
            port = Port,
            process_name = process_name_for(IpStr, Port),
            packet_module = PacketModule,
            packet_config = PacketConfig}.

ensure_relay_exists(X) ->
    #params{process_name = ProcessName} = Params = endpoint_params(X),
    case whereis(ProcessName) of
        undefined ->
            Pid = spawn(fun () -> relay_main(Params) end),
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
    #params{process_name = ProcessName} = endpoint_params(X),
    case whereis(ProcessName) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            ok
    end.

relay_main(Params = #params{}) ->
    receive
        stop ->
            ok;
        registered ->
            #params{ip_addr = IpAddr, port = Port} = Params,
            Opts = [{recbuf, 65536}, binary],
            {ok, Socket} = case IpAddr of
                               {0,0,0,0} -> gen_udp:open(Port, Opts);
                               _ -> gen_udp:open(Port, [{ip, IpAddr} | Opts])
                           end,
            relay_mainloop(Params, Socket)
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

udp_delivery(IpAddr = {A, B, C, D},
             Port,
             Packet,
             #params{exchange_def = #exchange{name = XName},
                     packet_module = PacketModule,
                     packet_config = PacketConfig}) ->
    case PacketModule:parse(IpAddr, Port, Packet, PacketConfig) of
        {ok, {RoutingKeySuffix, Properties, Body}} ->
            IpStr = list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])),
            RoutingKey = truncate_bin(255, list_to_binary(["ipv4",
                                                           ".", IpStr,
                                                           ".", integer_to_list(Port),
                                                           ".", RoutingKeySuffix])),
            {ok, rabbit_basic:delivery(false,
                                       rabbit_basic:message(XName, RoutingKey, Properties, Body),
                                       undefined)};
        ignore ->
            ignore;
        {error, Error} ->
            error_logger:error_report({?MODULE, PacketModule, parse, Error}),
            ignore
    end.

analyze_delivery(Delivery =
                     #delivery{message =
                                   #basic_message{routing_keys = [RoutingKey],
                                                  content =
                                                      #content{payload_fragments_rev =
                                                                   PayloadRev}}},
                 #params{packet_module = PacketModule,
                         packet_config = PacketConfig}) ->
    <<"ipv4.", Rest/binary>> = RoutingKey,
    [AStr, BStr, CStr, DStr, PortStr | RoutingKeySuffixes] = binary:split(Rest, <<".">>, [global]),
    A = list_to_integer(binary_to_list(AStr)),
    B = list_to_integer(binary_to_list(BStr)),
    C = list_to_integer(binary_to_list(CStr)),
    D = list_to_integer(binary_to_list(DStr)),
    IpAddr = {A, B, C, D},
    Port = list_to_integer(binary_to_list(PortStr)),
    PacketModule:format(IpAddr,
                        Port,
                        RoutingKeySuffixes,
                        list_to_binary(lists:reverse(PayloadRev)),
                        Delivery,
                        PacketConfig).

relay_mainloop(Params, Socket) ->
    receive
        stop ->
            ok = gen_udp:close(Socket);
        Delivery = #delivery{} ->
            case catch analyze_delivery(Delivery, Params) of
                {TargetIp, TargetPort, Packet} ->
                    ok = gen_udp:send(Socket, TargetIp, TargetPort, Packet);
                ignore ->
                    ok;
                {'EXIT', Reason} ->
                    %% Discard messages we can't shoehorn into UDP.
                    RKs = Delivery#delivery.message#basic_message.routing_keys,
                    #params{exchange_def = #exchange{name = XName},
                            packet_module = PacketModule} = Params,
                    error_logger:warning_report({?MODULE, PacketModule, format,
                                                 {Reason,
                                                  [{exchange, XName},
                                                   {routing_keys, RKs}]}}),
                    ok
            end,
            relay_mainloop(Params, Socket);
        {udp, _Socket, SourceIp, SourcePort, Packet} ->
            case udp_delivery(SourceIp, SourcePort, Packet, Params) of
                ignore ->
                    ok;
                {ok, Delivery} ->
                    ok = deliver(Params#params.exchange_def, Delivery)
            end,
            relay_mainloop(Params, Socket);
        Other ->
            exit({udp_exchange, relay, bad_message, Other})
    end.
