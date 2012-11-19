%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
-module(udp_exchange_stomp_packet).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include("udp_exchange_stomp_frame.hrl").

-export([configure/1, parse/4, format/6]).

-record(stomp_params, {routing_key_header}).

configure(#exchange{name = XName, arguments = Args}) ->
    RoutingKeyHeader =
        case rabbit_misc:table_lookup(Args, <<"routing_key_header">>) of
            {longstr, <<>>} -> none;
            {longstr, S} -> binary_to_list(S);
            undefined -> "destination";
            _ -> rabbit_misc:protocol_error
                   (precondition_failed,
                    "Invalid 'routing-key-header' argument to ~s (wrong type)",
                    [rabbit_misc:rs(XName)])
        end,
    #stomp_params{routing_key_header = RoutingKeyHeader}.

parse(_IpAddr, _Port, Packet, #stomp_params{routing_key_header = RoutingKeyHeader}) ->
    %% Add trailing NUL byte to let the implicit boundary of the
    %% packet terminate the STOMP frame.
    case udp_exchange_stomp_frame:parse(<<Packet/binary, 0>>,
                                        udp_exchange_stomp_frame:initial_state()) of
        {ok, Frame, _Remainder} ->
            #stomp_frame{command = Command, body_iolist = Body, headers = Headers} = Frame,
            RoutingKeySuffix =
                case RoutingKeyHeader of
                    none ->
                        list_to_binary(Command);
                    HeaderName ->
                        case udp_exchange_stomp_frame:header(Frame, HeaderName) of
                            not_found ->
                                list_to_binary(Command);
                            {ok, Value} ->
                                list_to_binary(Command ++ "." ++ Value)
                        end
                end,
            {ok, {RoutingKeySuffix,
                  [{headers, [{list_to_binary(K), longstr, list_to_binary(V)}
                              || {K, V} <- Headers]}],
                  iolist_to_binary(Body)}};
        _ ->
            {error, {stomp_syntax_error, udp_exchange:truncate_bin(255, Packet)}}
    end.

format(IpAddr,
       Port,
       [CommandBin | RoutingKeySuffixes],
       Body,
       #delivery{message = #basic_message{content = Content}},
       #stomp_params{routing_key_header = RoutingKeyHeader}) ->
    #content{properties = Props} = rabbit_binary_parser:ensure_content_decoded(Content),
    ContentHeaders = [{binary_to_list(K), binary_to_list(V)}
                      || {K, longstr, V} <- case Props#'P_basic'.headers of
                                                undefined -> [];
                                                Hs -> Hs
                                            end],
    Headers = case RoutingKeyHeader of
                  none ->
                      ContentHeaders;
                  HeaderName ->
                      RK = string:join([binary_to_list(F) || F <- RoutingKeySuffixes], "."),
                      [{HeaderName, RK}] ++ ContentHeaders
              end,
    {IpAddr, Port, udp_exchange_stomp_frame:serialize
                     (#stomp_frame{command = binary_to_list(CommandBin),
                                   headers = Headers,
                                   body_iolist = Body})}.
