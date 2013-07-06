# RabbitMQ "UDP Exchange" Plugin

Extends RabbitMQ Server with support for a new experimental exchange
type, `x-udp`.

Each created `x-udp` exchange listens on a specified UDP port for
incoming messages, and relays them on to the queues bound to the
exchange. It also takes messages published to the exchange and relays
them on to a specified IP address and UDP port.

## Prebuilt Binary Downloads

From time to time, I make a snapshot binary download of the plugin
available: see
<http://eighty-twenty.org/tech/rabbitmq/binary-plugins.html>. Expect
plugins to have a GPG signature from `tonygarnockjones@gmail.com`, key
available
[here](http://homepages.kcbbs.gen.nz/tonyg/gpg-key-gmail.txt),
fingerprint `630A 8781 4B1F A5BA C30F  A95D 6141 87C4 CEB5 3E0C`.

## Declaring an `x-udp` exchange

Call your `exchange_declare` command with the following arguments in
the `arguments` table:

    Key    Type    Optional? Description
    ------------------------------------------------------------------------
    port   short   no        Port number to listen for incoming packets on
    ip     string  yes       IP address to listen on; default is 0.0.0.0
    format string  yes       Module to use for packet parsing and formatting; default "raw"

The `ip` string, if supplied, must be a numeric IPv4 address string of
the form `X.Y.Z.W`. If `ip` is missing, the exchange will listen at
the specified port on all interfaces.

## Deleting an `x-udp` exchange

Deleting an `x-udp` exchange causes the system to stop listening for
UDP packets on the exchange's configured port.

## Packet formats

The `format` string in the `arguments` table of `exchange_declare`
controls the packet parsing and formatting process. The possible
values for the string are documented below.

If the `format` string is omitted, `raw` is assumed.

### Raw packet format, `format = "raw"`

Messages arriving on the UDP socket associated with an `x-udp`
exchange in `raw` mode are translated into AMQP messages and routed to
bound queues. The `routing_key`s of the AMQP messages are of the form

    ipv4.X.Y.Z.W.Port.Prefix

where `X.Y.Z.W` is the numeric IPv4 address string that the UDP packet
was sent from, `Port` is the UDP port number that the packet was sent
from, and `Prefix` is the first few bytes of the packet itself. AMQP
`routing_key`s are not permitted to be longer than 255 bytes, so as
much of the packet's body is placed in the `routing_key` as will
fit. The remainder is discarded from the `routing_key`.

The body of each produced AMQP message is the entire body of the
received UDP packet.

### STOMP packet format, `format = "stomp"`

Messages arriving on the UDP socket associated with an `x-udp`
exchange in `stomp` mode are parsed as if they were complete
[STOMP](http://stomp.github.com/stomp-specification-1.1.html) protocol
frames. The `routing_key`s of the resulting AMQP messages are of the
form

    ipv4.X.Y.Z.W.Port.Command.Destination

where `X.Y.Z.W` is the numeric IPv4 address string that the UDP packet
was sent from, `Port` is the UDP port number that the packet was sent
from, `Command` is the command name from the STOMP frame, and
`Destination` is the contents of a distinguished routing-key header
field from the STOMP frame.

If the exchange was declared with a string-valued argument table entry
named `routing_key_header`, then the value of that table entry is used
as the STOMP header name to scan incoming frames for in calculating
the AMQP routing key to use when delivering them on to bound
queues. If the value of `routing_key_header` is the empty string, then
none of the headers on an incoming STOMP frame are treated as the
routing key; the `Destination` portion of the AMQP routing key is
simply left empty, and the complete collection of STOMP headers is
passed on to AMQP receivers as usual. If `routing_key_header` is not
specified, then the STOMP `destination` header is used.

    Value for routing_key_header   STOMP header used to extract routing key
    -----------------------------------------------------------------------
    missing                        "destination"
    ""                             none
    "example"                      "example"

No matter the choice of `routing_key_header`, *all* the headers from
the received STOMP frame are passed on as user headers in the AMQP
message, and the body of each produced AMQP message is the entire body
of the received STOMP frame.

### Syslog packet format, `format = "syslog"`

(Contributed by Lionel Cons.)

Messages arriving on the UDP socket associated with an `x-udp`
exchange in `syslog` mode are parsed as if they were in [BSD syslog
Protocol format (RFC 3164)](http://www.ietf.org/rfc/rfc3164.txt). The
`routing_key`s of the resulting AMQP messages are of the form

    ipv4.X.Y.Z.W.Port.Facility.Severity

where `X.Y.Z.W` and `Port` are as specified above, and `Facility` and
`Severity` are respectively the numerical facility and severity of the
syslog packet. The latter two also appear in the user headers of the
messages.

## Bindings from `x-udp` exchanges to AMQP queues

The `routing_key` of messages routed to queues is formatted as
described above in order to make AMQP's topic routing syntax useful
for selecting UDP messages to receive. All the normal topic
`routing_key` patterns are available.

For example, to receive all packets *sent* from port 1234, you would
bind your queue using a `routing_key` pattern of
`ipv4.*.*.*.*.1234.#`. To simply receive all incoming packets, you
would bind using a pattern of `#`.

When using the `raw` format, since the first few bytes of each packet
are placed in the `routing_key` field, you can route based on packet
prefix (so long as your data format uses `"."` in a compatible
way). When using the `stomp` format, the `routing_key` field is
computed based on the `routing_key_header` described above.

## Routing messages from AMQP outbound via UDP

### Raw UDP packets - `format = "raw"`

Messages published to a `raw`-mode `x-udp` exchange must have routing
keys of the form

    ipv4.X.Y.Z.W.Port

where `X.Y.Z.W` and `Port` are the numeric IP address and UDP port
number to send the packet to, respectively. If there are other
period-separated routing key segments following the `Port` segment of
the key, they are ignored. The packet's body will be the body of the
published AMQP message. The packet will be sent from the IP address
and port number that the exchange itself was declared with.

### STOMP UDP packets - `format = "stomp"`

Messages published to a `stomp`-mode `x-udp` exchange must have routing
keys of the form

    ipv4.X.Y.Z.W.Port.Command.Destination

as described above for `raw`-mode, except the `Command`, which is used
as the command portion of the STOMP frame to be sent, and the
`Destination`, which is optional, and used as the value for the
`routing_key_header`, if any.

The AMQP user headers are converted into STOMP headers. A STOMP
`content-length` header is added before sending. The body of the STOMP
frame UDP packet is just the body of the published AMQP message. The
packet will be sent from the IP address and port number that the
exchange itself was declared with.

### Syslog UDP packets - `format = "syslog"`

Outbound delivery of syslog-formatted packets is not yet implemented:
`syslog`-format UDP exchanges will only be able to receive syslog
packets.

## Limitations

Note that there may be platform and network-specific limitations on
the sizes of UDP packets that can be sent and received.

## Licensing

This plugin is licensed under the [MPL 2.0][]. The full license text is
included with the source code for the package. If you have any
questions regarding licensing, please contact
<tonygarnockjones@gmail.com>.

[MPL 2.0]: http://www.mozilla.org/MPL/2.0/
