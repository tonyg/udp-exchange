%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
-module(udp_exchange_relay).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("udp_exchange.hrl").

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {params, socket}).

start_link(Params = #params{process_name = ProcessName}) ->
    gen_server:start_link({local, ProcessName}, ?MODULE, [Params], []).

%%----------------------------------------------------------------------------

init([#params{ip_addr = IpAddr, port = Port} = Params]) ->
    Opts = [{recbuf, 65536}, binary],
    {ok, Socket} = case IpAddr of
                       {0,0,0,0} -> gen_udp:open(Port, Opts);
                       _ -> gen_udp:open(Port, [{ip, IpAddr} | Opts])
                   end,
    {ok, #state{params = Params, socket = Socket}}.

handle_call(Msg, _From, State) ->
    {stop, {unhandled_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unhandled_cast, Msg}, State}.

handle_info(Delivery = #delivery{}, State = #state{params = Params,
                                                   socket = Socket}) ->
    case catch analyze_delivery(Delivery, Params) of
        {TargetIp, TargetPort, Packet} ->
            ok = gen_udp:send(Socket, TargetIp, TargetPort, Packet);
        ignore ->
            ok;
        {'EXIT', Reason} ->
            %% Discard messages we can't shoehorn into UDP.
            RKs = (Delivery#delivery.message)#basic_message.routing_keys,
            #params{exchange_def = #exchange{name = XName},
                    packet_module = PacketModule} = Params,
            error_logger:warning_report({?MODULE, PacketModule, format,
                                         {Reason,
                                          [{exchange, XName},
                                           {routing_keys, RKs}]}}),
            ok
    end,
    {noreply, State};

handle_info({udp, _Socket, SourceIp, SourcePort, Packet},
            State = #state{params = Params}) ->
    case udp_delivery(SourceIp, SourcePort, Packet, Params) of
        ignore ->
            ok;
        {ok, Delivery} ->
            ok = udp_exchange:deliver(Params#params.exchange_def, Delivery)
    end,
    {noreply, State};

handle_info(Msg, State) ->
    {stop, {unhandled_info, Msg}, State}.

terminate(_Reason, #state{socket = Socket}) ->
    ok = gen_udp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

analyze_delivery(Delivery =
                     #delivery{message =
                                   #basic_message{routing_keys = [RoutingKey],
                                                  content =
                                                      #content{payload_fragments_rev =
                                                                   PayloadRev}}},
                 #params{packet_module = PacketModule,
                         packet_config = PacketConfig}) ->
    <<"ipv4.", Rest/binary>> = RoutingKey,
    %% re:split(X,Y) can be replaced with binary:split(X,Y,[global]) once we
    %% drop support for Erlangs older than R14.
    [AStr, BStr, CStr, DStr, PortStr | RoutingKeySuffixes] = re:split(Rest, "\\."),
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

udp_delivery(IpAddr = {A, B, C, D},
             Port,
             Packet,
             #params{exchange_def = #exchange{name = XName},
                     packet_module = PacketModule,
                     packet_config = PacketConfig}) ->
    case PacketModule:parse(IpAddr, Port, Packet, PacketConfig) of
        {ok, {RoutingKeySuffix, Properties, Body}} ->
            IpStr = list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])),
            RoutingKey = udp_exchange:truncate_bin(
                           255, list_to_binary(["ipv4",
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
