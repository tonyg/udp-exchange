//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
package lfp.rabbitmq.udpexchange.tests;

import com.rabbitmq.client.ShutdownSignalException;
import com.rabbitmq.client.test.BrokerTestCase;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/**
 */
public class UdpExchangeBogusFormatTests extends BrokerTestCase {
    public void testBadFormatParameter() throws IOException {
        Map<String, Object> declArgs = new HashMap<String, Object>();
        declArgs.put("ip", "0.0.0.0");
        declArgs.put("port", (short) 5672);
        declArgs.put("format", "some_nonexistent_format_name");
        try {
            channel.exchangeDeclare("Bogus UDP Exchange", "x-udp", false, false, declArgs);
        } catch (IOException ioe) {
            checkShutdownSignal(406, ioe);
        }
    }
}
