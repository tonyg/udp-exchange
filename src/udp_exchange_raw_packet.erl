-module(udp_exchange_raw_packet).
-include_lib("rabbit_common/include/rabbit.hrl").

-export([configure/1, parse/4, format/6]).

configure(#exchange{}) ->
    no_config.

parse({A, B, C, D}, Port, Packet, _Config) ->
    IpStr = list_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D])),
    %% FIXME: use more clever end-of-routing key detection
    {ok, {udp_exchange:truncate_bin(255, Packet),
          [{headers, [{<<"source_ip">>, longstr, IpStr},
                      {<<"source_port">>, signedint, Port}]}],
          Packet}}.

format(IpAddr, Port, _RoutingKeySuffixes, Body, #delivery{}, _Config) ->
    {IpAddr, Port, Body}.
