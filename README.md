# RabbitMQ "UDP Exchange" Plugin

Extends RabbitMQ Server with support for a new experimental exchange
type, `x-udp`.

Each created `x-udp` exchange listens on a specified UDP port for
incoming messages, and relays them on to the queues bound to the
exchange. It also takes messages published to the exchange and relays
them on to a specified IP address and UDP port.

## Declaring an `x-udp` exchange

Call your `exchange_declare` command with the following arguments in
the `arguments` table:

    Key   Type    Optional? Description
    -----------------------------------------------------------------------
    port  short   no        Port number to listen for incoming packets on
    ip    string  yes       IP address to listen on; default is 0.0.0.0

The `ip` string, if supplied, must be a numeric IPv4 address string of
the form `X.Y.Z.W`. If `ip` is missing, the exchange will listen at
the specified port on all interfaces.

## Deleting an `x-udp` exchange

Deleting an `x-udp` exchange causes the system to stop listening for
UDP packets on the exchange's configured port.

## Messages arriving from UDP

Messages arriving on the UDP socket associated with an `x-udp`
exchange are translated into AMQP messages and routed to bound
queues. The `routing_key`s of the AMQP messages are of the form

    ipv4.X.Y.Z.W.Port.Prefix

where `X.Y.Z.W` is the numeric IPv4 address string that the UDP packet
was sent from, `Port` is the UDP port number that the packet was sent
from, and `Prefix` is the first few bytes of the packet itself. AMQP
`routing_key`s are not permitted to be longer than 255 bytes, so as
much of the packet's body is placed in the `routing_key` as will
fit. The remainder is discarded from the `routing_key`.

The body of each produced AMQP message is the entire body of the
received UDP packet.

## Bindings from `x-udp` exchanges to AMQP queues

The `routing_key` of messages routed to queues is formatted as
described above in order to make AMQP's topic routing syntax useful
for selecting UDP messages to receive. All the normal topic
`routing_key` patterns are available.

For example, to receive all packets *sent* from port 1234, you would
bind your queue using a `routing_key` pattern of
`ipv4.*.*.*.*.1234.#`. To simply receive all incoming UDP packets, you
would bind using a pattern of `#`.

Since the first few bytes of each packet are placed in the
`routing_key` field, you can route based on packet prefix (so long as
your data format uses `"."` in a compatible way).

## Messages to be sent to UDP

Messages published to an `x-udp` exchange must have routing keys of
the form

    ipv4.X.Y.Z.W.Port

where `X.Y.Z.W` and `Port` are the numeric IP address and UDP port
number to send the packet to, respectively. If there are other
period-separated routing key segments following the `Port` segment of
the key, they are ignored. The packet's body will be the body of the
published AMQP message. The packet will be sent from the IP address
and port number that the exchange itself was declared with.

Note that there may be platform and network-specific limitations on
the sizes of UDP packets that can be sent and received.

## Licensing

This plugin is licensed under the MPL. The full license text is
included with the source code for the package. If you have any
questions regarding licensing, please contact
<tonygarnockjones@gmail.com>.
