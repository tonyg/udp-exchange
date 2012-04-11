# Things to do

 - add an option to disable outbound UDP sending on a per-exchange basis
 - perhaps the same for inbound?? so have two orthogonal flags
 - add an option to include `source_ip` and `source_port` user-headers
   in relayed AMQP messages, so that people don't have to rely on
   getting an unadulterated `routing_key`
