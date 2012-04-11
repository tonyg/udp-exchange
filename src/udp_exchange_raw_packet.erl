-module(udp_exchange_raw_packet).
-include_lib("rabbit_common/include/rabbit.hrl").

-export([configure/1, parse/4, format/6]).

configure(#exchange{}) ->
    no_config.

parse(_IpAddr, _Port, Packet, _Config) ->
    %% FIXME: use more clever end-of-routing key detection
    {ok, {udp_exchange:truncate_bin(255, Packet),
          [],
          Packet}}.

format(IpAddr, Port, _RoutingKeySuffixes, Body, #delivery{}, _Config) ->
    {IpAddr, Port, Body}.
