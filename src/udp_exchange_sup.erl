%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
-module(udp_exchange_sup).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("udp_exchange.hrl").

-rabbit_boot_step({udp_supervisor,
                   [{description, "udp"},
                    {mfa,         {rabbit_sup, start_child, [?MODULE]}},
                    {requires,    kernel_ready},
                    {enables,     udp_exchange}]}).


-behaviour(supervisor).
-export([start_link/0, ensure_started/1, stop/1, endpoint_params/1]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

ensure_started(X) ->
    #params{process_name = ProcessName} = Params = endpoint_params(X),
    case whereis(ProcessName) of
        undefined ->
            case supervisor:start_child(
                   ?MODULE,
                   {ProcessName, {udp_exchange_relay, start_link, [Params]},
                    transient, ?MAX_WAIT, worker, [udp_exchange_relay]}) of
                {ok,              Pid} -> Pid;
                {already_started, Pid} -> Pid
            end;
        Pid ->
            Pid
    end.

stop(X) ->
    #params{process_name = ProcessName} = endpoint_params(X),
    ok = supervisor:terminate_child(?MODULE, ProcessName),
    ok = supervisor:delete_child(?MODULE, ProcessName).

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

process_name_for(IpStr, Port) ->
    list_to_atom("udp_exchange_" ++ IpStr ++ "_" ++ integer_to_list(Port)).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.
