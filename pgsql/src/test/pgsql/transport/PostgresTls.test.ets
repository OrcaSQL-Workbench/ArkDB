import { socket } from '@kit.NetworkKit';
import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  buildPostgresTlsConnectOptions, createDefaultPostgresTlsIdentityVerifier,
  PostgresTlsFilePort
} from '../../../main/ets/pgsql/transport/PostgresTcpTransport';
import { PostgresSslConfig, PostgresSslMode } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
export default function postgresTlsTest(): void {
  describe('PostgresTls', () => {
    it('buildsModeSpecificTlsOptionsAndLoadsBoundedCredentials', 0, () => {
      const files = new MockTlsFiles();
      const required = new PostgresSslConfig();
      required.mode = PostgresSslMode.REQUIRED;
      required.caCertPath = 'ca.pem';
      let options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        required, 0xFFFFFFFF, files);
      expect(options.address.address).assertEqual('db.example.com');
      expect(options.address.port).assertEqual(5432);
      expect(options.timeout).assertEqual(0xFFFFFFFF);
      expect(options.skipRemoteValidation).assertTrue();
      expect(options.secureOptions.ca === undefined).assertTrue();
      expect(files.readPaths.length).assertEqual(0);
      const verified = new PostgresSslConfig();
      verified.mode = PostgresSslMode.VERIFY_CA;
      verified.caCertPath = ' ca.pem ';
      verified.clientCertPath = ' client.pem ';
      verified.clientKeyPath = ' key.pem ';
      verified.tlsVersions = ['TLSv1.2', 'TLSv1.3'];
      verified.cipherSuites = ' TLS_AES_128_GCM_SHA256 ';
      options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        verified, 3000, files);
      expect(options.skipRemoteValidation).assertFalse();
      expect(options.secureOptions.ca).assertEqual('CA');
      expect(options.secureOptions.cert).assertEqual('CERT');
      expect(options.secureOptions.key).assertEqual('KEY');
      expect(options.secureOptions.isBidirectionalAuthentication).assertTrue();
      expect(options.secureOptions.cipherSuite)
        .assertEqual('TLS_AES_128_GCM_SHA256');
      const protocols = options.secureOptions.protocols!;
      expect(protocols.length).assertEqual(2);
      expect(protocols[0]).assertEqual(socket.Protocol.TLSv12);
      expect(protocols[1]).assertEqual(socket.Protocol.TLSv13);
      expect(files.readPaths.join(','))
        .assertEqual('ca.pem,client.pem,key.pem');
      expect(files.maximumBytes).assertEqual(1024 * 1024);
      const verifyFull = new PostgresSslConfig();
      verifyFull.mode = PostgresSslMode.VERIFY_FULL;
      options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        verifyFull, 1, files);
      expect(options.skipRemoteValidation).assertFalse();
    });
    it('rejectsDisabledTlsInvalidCredentialsVersionsAndFiles', 0, () => {
      const files = new MockTlsFiles();
      const config = new PostgresSslConfig();
      config.mode = PostgresSslMode.DISABLED;
      expectOptionsFailure(config, files, 1000, 'PostgreSQL TLS is disabled');
      config.mode = 'invalid' as PostgresSslMode;
      expectOptionsFailure(config, files, 1000,
        'Unsupported PostgreSQL TLS mode: invalid');
      config.mode = PostgresSslMode.REQUIRED;
      for (const timeout of [
        0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 0x100000000
      ]) {
        expectOptionsFailure(config, files, timeout,
          'PostgreSQL TLS timeout must be between 1 and 4294967295 milliseconds');
      }
      config.clientCertPath = 'client.pem';
      expectOptionsFailure(config, files, 1000,
        'Client certificate and private key must be configured together');
      config.clientCertPath = undefined;
      config.clientKeyPath = 'key.pem';
      expectOptionsFailure(config, files, 1000,
        'Client certificate and private key must be configured together');
      config.clientCertPath = 'client.pem';
      config.tlsVersions = ['TLSv1.1'];
      expectOptionsFailure(config, files, 1000,
        'Unsupported TLS version: TLSv1.1');
      config.tlsVersions = ['TLSv1.2', ''];
      expectOptionsFailure(config, files, 1000, 'Unsupported TLS version: ');
      config.tlsVersions = ['TLSv1.2'];
      files.failedPath = 'client.pem';
      files.failedMessage = 'client certificate file must be between 1 byte and 1 MiB';
      expectOptionsFailure(config, files, 1000,
        'Could not read client certificate file: ' + files.failedMessage);
    });
    it('failsClosedWhenVerifyFullHasNoProductionIdentityVerifier', 0, async () => {
      const verifier = createDefaultPostgresTlsIdentityVerifier();
      const certificate = {} as socket.X509CertRawData;
      const terminal = await failure((): Promise<void> =>
        verifier.verify(certificate, 'db.example.com'));
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(terminal.nativeCode).assertEqual(
        'TLS_IDENTITY_VERIFIER_UNAVAILABLE');
      expect(terminal.message).assertEqual(
        'PostgreSQL VERIFY_FULL identity verification is not available in this build');
    });
  });
}
class MockTlsFiles implements PostgresTlsFilePort {
  maximumBytes: number = 0;
  readPaths: string[] = [];
  failedPath: string = '';
  failedMessage: string = '';
  read(path: string, maximumBytes: number, label: string): string {
    this.maximumBytes = maximumBytes;
    this.readPaths.push(path);
    if (path === this.failedPath) throw new Error(this.failedMessage);
    if (path === 'ca.pem') return 'CA';
    if (path === 'client.pem') return 'CERT';
    if (path === 'key.pem') return 'KEY';
    throw new Error('Unexpected TLS fixture path for ' + label);
  }
}
function expectOptionsFailure(config: PostgresSslConfig,
  files: PostgresTlsFilePort, timeoutMs: number, message: string): void {
  let terminal: ArkDbError | null = null;
  try {
    buildPostgresTlsConnectOptions(
      'db.example.com', 5432, config, timeoutMs, files);
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.message).assertEqual(message);
}
async function failure(operation: () => Promise<void>): Promise<ArkDbError> {
  let terminal: ArkDbError | null = null;
  try {
    await operation();
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  return terminal!;
}
