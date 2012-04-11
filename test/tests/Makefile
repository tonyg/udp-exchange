RABBIT_JAVA_JAR_DIR:=$(shell echo `pwd`/../../../rabbitmq-java-client/build/dist)
JARS:=$(shell ls $(RABBIT_JAVA_JAR_DIR)/*.jar | tr '\n' ':')
OUTDIR:=$(CURDIR)/class

run-tests: classes
	(cd $(OUTDIR); java -cp $(JARS) junit.textui.TestRunner lfp.rabbitmq.udpexchange.tests.UdpExchangeTests)
	(cd $(OUTDIR); java -cp $(JARS) junit.textui.TestRunner lfp.rabbitmq.udpexchange.tests.UdpExchangeBogusFormatTests)

classes: $(OUTDIR)
	(cd src; javac -cp $(JARS) -d $(OUTDIR) $$(find . -iname '*.java'))

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -rf $(OUTDIR)
