package lfp.rabbitmq.udpexchange.tests;

import com.rabbitmq.client.GetResponse;
import com.rabbitmq.client.LongString;
import com.rabbitmq.client.test.BrokerTestCase;

import java.io.IOException;
import java.net.*;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 */
public class UdpExchangeTests extends BrokerTestCase {
    final String xname = "UDP exchange for testing"; /* Udp exchange name */
    final String xtype = "x-udp";

    String q1;
    DatagramSocket u;
    DatagramPacket pOut, pIn;

    @Override public void createResources() throws IOException {
        Map<String, Object> declArgs = new HashMap<String, Object>();
        declArgs.put("ip", "0.0.0.0");
        declArgs.put("port", (short) 5672);
        channel.exchangeDeclare(xname, xtype, false, false, declArgs);

        q1 = channel.queueDeclare().getQueue();
        channel.queueBind(q1, xname, "ipv4.#");

        u = new DatagramSocket();
        u.setSoTimeout(1000); // milliseconds
        pOut = new DatagramPacket(new byte[65536], 65536, InetAddress.getLocalHost(), 5672);
        pIn = new DatagramPacket(new byte[65536], 65536);
    }

    @Override public void releaseResources() throws IOException {
        // Note that the temporary queues are taken care of by the
        // disconnection and reconnection involved in the test framework.
        channel.exchangeDelete(xname);
    }

    public void assertEmpty(String qname) throws IOException {
        assertNull(basicGet(qname));
    }

    public void testDeclareAndDelete() throws IOException {
        // Just the createResources and releaseResources suffice.
    }
    
    public void sendString(String s) throws IOException {
        byte[] encoded = s.getBytes("utf-8");
        System.arraycopy(encoded, 0, pOut.getData(), 0, encoded.length);
        pOut.setLength(encoded.length);
        u.send(pOut);
    }
    
    public String recvString() throws IOException {
        u.receive(pIn);
        return new String(pIn.getData(), 0, pIn.getLength(), "utf-8");
    }
    
    public void testUdpSendAmqpReceive() throws IOException {
        String message = "Hello from UDP";
        sendString(message);
        GetResponse r = basicGet(q1);
        assertNotNull(r);
        assertEquals(message, new String(r.getBody(), "utf-8"));
    }

    public void testAmqpSendUdpReceive() throws IOException {
        String message = "Hello from AMQP";
        String routingKey = "ipv4." + InetAddress.getLocalHost().getHostAddress() + "." + u.getLocalPort();
        basicPublishVolatile(message.getBytes("utf-8"), xname, routingKey);
        sendString(message);
        assertEquals(message, recvString());
    }

    public void testAmqpSendBadRK() throws IOException {
        String message = "Not a message that should end up in UDP-land";
        String routingKey = "not_valid.for.routing";
        basicPublishVolatile(message.getBytes("utf-8"), xname, routingKey);
        sendString(message);
        try {
            recvString();
            fail("Message received when no message was expected");
        } catch (SocketTimeoutException ste) {
            // OK.
        }
    }
}
