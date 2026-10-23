import connectionConfigTest from './connection/ConnectionConfig.test';
import loggerPrivacyTest from './diagnostics/LoggerPrivacy.test';
import serverMetricsTest from './metrics/ServerMetrics.test';
import tcpTransportTest from './transport/TcpTransport.test';

export default function testsuite(): void {
  connectionConfigTest();
  loggerPrivacyTest();
  serverMetricsTest();
  tcpTransportTest();
}
