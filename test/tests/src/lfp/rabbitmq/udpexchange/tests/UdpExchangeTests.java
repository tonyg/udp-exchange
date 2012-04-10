package lfp.rabbitmq.udpexchange.tests;

import com.rabbitmq.client.GetResponse;
import com.rabbitmq.client.test.BrokerTestCase;

import java.io.IOException;
import java.io.UnsupportedEncodingException;
import java.net.*;
import java.util.HashMap;
import java.util.Map;

/**
 */
public class UdpExchangeTests extends BrokerTestCase {
    final String xnameRaw = "UDP raw exchange for testing";
    final String xnameStompDefault = "Default UDP stomp exchange for testing";
    final String xnameStompCustom = "Custom UDP stomp exchange for testing";
    final String xnameStompPlain = "Plain UDP stomp exchange for testing";
    final String xtype = "x-udp";

    String q1;
    DatagramSocket u;
    DatagramPacket pOutRaw, pOutStompDefault, pOutStompCustom, pOutStompPlain, pIn;

    @Override public void createResources() throws IOException {
        Map<String, Object> declArgs = new HashMap<String, Object>();
        declArgs.put("ip", "0.0.0.0");
        declArgs.put("port", (short) 5672);
        channel.exchangeDeclare(xnameRaw, xtype, false, false, declArgs);

        declArgs.put("port", (short) 61613);
        declArgs.put("format", "stomp");
        channel.exchangeDeclare(xnameStompDefault, xtype, false, false, declArgs);

        declArgs.put("port", (short) 61614);
        declArgs.put("routing_key_header", "rk");
        channel.exchangeDeclare(xnameStompCustom, xtype, false, false, declArgs);

        declArgs.put("port", (short) 61615);
        declArgs.put("routing_key_header", "");
        channel.exchangeDeclare(xnameStompPlain, xtype, false, false, declArgs);

        q1 = channel.queueDeclare().getQueue();
        channel.queueBind(q1, xnameRaw, "ipv4.#");
        channel.queueBind(q1, xnameStompDefault, "ipv4.#");
        channel.queueBind(q1, xnameStompCustom, "ipv4.#");
        channel.queueBind(q1, xnameStompPlain, "ipv4.#");

        u = new DatagramSocket();
        u.setSoTimeout(1000); // milliseconds
        pOutRaw = new DatagramPacket(new byte[65536], 65536, InetAddress.getLocalHost(), 5672);
        pOutStompDefault = new DatagramPacket(new byte[65536], 65536, InetAddress.getLocalHost(), 61613);
        pOutStompCustom = new DatagramPacket(new byte[65536], 65536, InetAddress.getLocalHost(), 61614);
        pOutStompPlain = new DatagramPacket(new byte[65536], 65536, InetAddress.getLocalHost(), 61615);
        pIn = new DatagramPacket(new byte[65536], 65536);
    }

    @Override public void releaseResources() throws IOException {
        // Note that the temporary queues are taken care of by the
        // disconnection and reconnection involved in the test framework.
        channel.exchangeDelete(xnameRaw);
        channel.exchangeDelete(xnameStompDefault);
        channel.exchangeDelete(xnameStompCustom);
        channel.exchangeDelete(xnameStompPlain);
    }

    public void assertEmpty(String qname) throws IOException {
        assertNull(basicGet(qname));
    }

    public void testDeclareAndDelete() throws IOException {
        // Just the createResources and releaseResources suffice.
    }
    
    public void sendString(String s, DatagramPacket p) throws IOException {
        byte[] encoded = s.getBytes("utf-8");
        System.arraycopy(encoded, 0, p.getData(), 0, encoded.length);
        p.setLength(encoded.length);
        u.send(p);
    }
    
    public String recvString(DatagramPacket p) throws IOException {
        u.receive(p);
        return new String(p.getData(), 0, p.getLength(), "utf-8");
    }
    
    public void testUdpSendAmqpReceive() throws IOException {
        String message = "Hello from UDP";
        sendString(message, pOutRaw);
        GetResponse r = basicGet(q1);
        assertNotNull(r);
        assertEquals(message, new String(r.getBody(), "utf-8"));
    }

    public String stompFrameToSend() {
        return "COMMAND\ndestination:rk1\nrk:rk2\nheader1:value1\nheader2:value2\n\nHello STOMP";
    }

    public void checkReceivedStompDelivery(String expectedRKSuffix)
            throws IOException
    {
        GetResponse r = basicGet(q1);
        assertNotNull(r);
        assertTrue("Delivery has correct routing key", r.getEnvelope().getRoutingKey().endsWith(expectedRKSuffix));
        assertEquals("rk1", r.getProps().getHeaders().get("destination").toString());
        assertEquals("rk2", r.getProps().getHeaders().get("rk").toString());
        assertEquals("value1", r.getProps().getHeaders().get("header1").toString());
        assertEquals("value2", r.getProps().getHeaders().get("header2").toString());
        assertEquals("Hello STOMP", new String(r.getBody(), "utf-8"));
    }
    
    public void checkStompRead(DatagramPacket p, String expectedRKSuffix) throws IOException, InterruptedException {
        sendString(stompFrameToSend(), p);
        Thread.sleep(250); // give it time to receive the packet
        checkReceivedStompDelivery(expectedRKSuffix);
    }

    public void testStompDefaultSendAmqpReceive() throws IOException, InterruptedException {
        checkStompRead(pOutStompDefault, ".COMMAND.rk1");
    }

    public void testStompCustomSendAmqpReceive() throws IOException, InterruptedException {
        checkStompRead(pOutStompCustom, ".COMMAND.rk2");
    }

    public void testStompPlainSendAmqpReceive() throws IOException, InterruptedException {
        checkStompRead(pOutStompPlain, ".COMMAND");
    }

    public void testAmqpSendUdpReceive() throws IOException {
        String message = "Hello from AMQP";
        String routingKey = "ipv4." + InetAddress.getLocalHost().getHostAddress() + "." + u.getLocalPort();
        basicPublishVolatile(message.getBytes("utf-8"), xnameRaw, routingKey);
        assertEquals(message, recvString(pIn));
    }

    public void checkStompWrite(String x, String expectedRKheader) throws IOException {
        String message = "Hello from AMQP";
        String routingKey = "ipv4." + InetAddress.getLocalHost().getHostAddress() + "." + u.getLocalPort() + ".CMD.rk";
        basicPublishVolatile(message.getBytes("utf-8"), x, routingKey);
        String frame = recvString(pIn);
        if (expectedRKheader == null) {
            assertEquals("CMD\ncontent-length:15\n\nHello from AMQP\0", frame);
        } else {
            assertEquals("CMD\n" + expectedRKheader + ":rk\ncontent-length:15\n\nHello from AMQP\0", frame);
        }
    }

    public void testAmqpSendStompDefaultReceive() throws IOException {
        checkStompWrite(xnameStompDefault, "destination");
    }

    public void testAmqpSendStompCustomReceive() throws IOException {
        checkStompWrite(xnameStompCustom, "rk");
    }

    public void testAmqpSendStompPlainReceive() throws IOException {
        checkStompWrite(xnameStompPlain, null);
    }

    public void testAmqpSendBadRK() throws IOException {
        String message = "Not a message that should end up in UDP-land";
        String routingKey = "not_valid.for.routing";
        basicPublishVolatile(message.getBytes("utf-8"), xnameRaw, routingKey);
        sendString(message, pOutRaw);
        try {
            recvString(pIn);
            fail("Message received when no message was expected");
        } catch (SocketTimeoutException ste) {
            // OK.
        }
    }
}
