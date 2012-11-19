%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% udp-exchange syslog module
%% Contributed by Lionel Cons.
%%
%% Messages arriving on the UDP socket associated with an x-udp exchange
%% in syslog mode are parsed as if they were in BSD syslog Protocol
%% format (RFC 3164). The routing_keys of the resulting AMQP messages are
%% of the form
%%
%%   ipv4.X.Y.Z.W.Port.Facility.Severity
%%
%% where X.Y.Z.W is the numeric IPv4 address string that the UDP packet
%% was sent from, Port is the UDP port number that the packet was sent
%% from, Facility and Severity are respectively the numerical facility
%% and severity of the syslog packet. The latter two also appear in the
%% user headers of the messages.
%%

-module(udp_exchange_syslog_packet).
-include_lib("rabbit_common/include/rabbit.hrl").

-export([configure/1, parse/4, format/6]).

configure(#exchange{}) ->
    no_config.

rfc3164_parse(<<$0, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+0);
rfc3164_parse(<<$1, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+1);
rfc3164_parse(<<$2, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+2);
rfc3164_parse(<<$3, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+3);
rfc3164_parse(<<$4, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+4);
rfc3164_parse(<<$5, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+5);
rfc3164_parse(<<$6, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+6);
rfc3164_parse(<<$7, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+7);
rfc3164_parse(<<$8, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+8);
rfc3164_parse(<<$9, Rest/binary>>, PriVal) ->
    rfc3164_parse(Rest, PriVal*10+9);
rfc3164_parse(<<$>, Rest/binary>>, PriVal) ->
    {ok, PriVal div 8, PriVal rem 8, Rest};
rfc3164_parse(_Data, _PriVal) ->
    error.

rfc3164_parse(<<$<, Rest/binary>>) ->
    rfc3164_parse(Rest, 0);
rfc3164_parse(_Data) ->
    error.

parse(_IpAddr, _Port, Packet, _Config) ->
    case rfc3164_parse(Packet) of
        {ok, Facility, Severity, Rest} ->
            {ok, {list_to_binary(io_lib:format("~p.~p", [Facility, Severity])),
                  [{headers, [{<<"facility">>, signedint, Facility},
                              {<<"severity">>, signedint, Severity}]}],
                  Rest}};
        _ ->
            {error, {rfc3164_parsing_error, udp_exchange:truncate_bin(255, Packet)}}
    end.

format(_IpAddr, _Port, _RoutingKeySuffixes, _Body, #delivery{}, _Config) ->
    %% FIXME: shall we extract facility and severity from message properties? routing key?
    %% FIXME: For now, I've disabled outbound syslog.
    %% {IpAddr, Port, Body}.
    ignore.
