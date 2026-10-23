import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionConfig,
  ConnectionConfigField,
  ArkDbErrorKind,
  SslMode
} from '../../../../Index';

export default function connectionConfigTest(): void {
  describe('ConnectionConfig', () => {
    it('reportsMissingConnectionFieldsInStableOrder', 0, () => {
      const config = new ConnectionConfig();

      const issues = config.validateIssues();

      expect(issues.length).assertEqual(2);
      expect(issues[0].field).assertEqual(ConnectionConfigField.Host);
      expect(issues[0].error.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(issues[0].error.message).assertEqual('Host is required');
      expect(issues[0].invalidValue === undefined).assertTrue();
      expect(issues[1].field).assertEqual(ConnectionConfigField.User);
      expect(issues[1].error.message).assertEqual('Username is required');
    });

    it('acceptsConnectionOptionsWithoutSavedProfileOrIgnoredSettings', 0, () => {
      const config = validConfig();
      expect(config.validate().length).assertEqual(0);
      const serialized = JSON.stringify(config);
      const excluded: string[] = ['id', 'name', 'group', 'driverId', 'filePath',
        'driverOptionsJson', 'charset', 'compression', 'sqlMode', 'connectionAttributes'];
      for (const field of excluded) {
        expect(serialized.indexOf('"' + field + '":')).assertEqual(-1);
      }
    });

    it('clonesSupportedOptionsAndIsolatesTlsConfiguration', 0, () => {
      const config = validConfig();
      config.port = 3307;
      config.defaultSchema = 'shop';
      config.connectTimeoutMs = 2500;
      config.autocommit = false;
      config.ssl.mode = SslMode.VERIFY_IDENTITY;
      config.ssl.caCertPath = 'fixture-ca.pem';
      config.ssl.clientCertPath = 'fixture-client.pem';
      config.ssl.clientKeyPath = 'fixture-client-key.pem';
      config.ssl.cipherSuites = 'TLS_AES_128_GCM_SHA256';
      const versions: string[] = ['TLSv1.2'];
      config.ssl.tlsVersions = versions;

      const copy = config.clone();

      expect(copy.host).assertEqual(config.host);
      expect(copy.user).assertEqual(config.user);
      expect(copy.port).assertEqual(3307);
      expect(copy.defaultSchema).assertEqual('shop');
      expect(copy.connectTimeoutMs).assertEqual(2500);
      expect(copy.autocommit).assertFalse();
      expect(copy.ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
      expect(copy.ssl.caCertPath).assertEqual('fixture-ca.pem');
      expect(copy.ssl.clientCertPath).assertEqual('fixture-client.pem');
      expect(copy.ssl.clientKeyPath).assertEqual('fixture-client-key.pem');
      expect(copy.ssl.cipherSuites).assertEqual('TLS_AES_128_GCM_SHA256');
      const copiedVersions = copy.ssl.tlsVersions;
      if (copiedVersions === undefined) throw new Error('Cloned TLS versions are missing');
      copiedVersions.push('TLSv1.3');
      copy.ssl.mode = SslMode.DISABLED;
      expect(versions.length).assertEqual(1);
      expect(config.ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
    });

    it('rejectsInvalidPorts', 0, () => {
      const invalidPorts: number[] = [0, 65536, 3306.5, Number.NaN];

      for (const port of invalidPorts) {
        const config = validConfig();
        config.port = port;

        const issues = config.validateIssues();
        expect(issues.length).assertEqual(1);
        expect(issues[0].field).assertEqual(ConnectionConfigField.Port);
        expect(issues[0].error.message).assertEqual('Port must be between 1 and 65535');
      }
    });

    it('rejectsInvalidConnectTimeouts', 0, () => {
      const invalidTimeouts: number[] = [0, 1000.5, 9007199254740992, Number.NaN];

      for (const timeout of invalidTimeouts) {
        const config = validConfig();
        config.connectTimeoutMs = timeout;

        const issues = config.validateIssues();
        expect(issues.length).assertEqual(1);
        expect(issues[0].field).assertEqual(ConnectionConfigField.ConnectTimeoutMs);
        expect(issues[0].error.message).assertEqual('Connect timeout must be a positive integer');
      }
    });

    it('requiresClientCertificateAndKeyTogether', 0, () => {
      const certificateOnly = validConfig();
      certificateOnly.ssl.clientCertPath = '/data/client.pem';

      const keyOnly = validConfig();
      keyOnly.ssl.clientKeyPath = '/data/client-key.pem';

      expect(certificateOnly.validateIssues().length).assertEqual(1);
      expect(certificateOnly.validateIssues()[0].field)
        .assertEqual(ConnectionConfigField.ClientCredentials);
      expect(keyOnly.validateIssues().length).assertEqual(1);
      expect(keyOnly.validateIssues()[0].field)
        .assertEqual(ConnectionConfigField.ClientCredentials);
    });

    it('rejectsUnsupportedTlsVersions', 0, () => {
      const config = validConfig();
      config.ssl.tlsVersions = ['TLSv1.2', ' TLSv1.1 '];

      const issues = config.validateIssues();

      expect(issues.length).assertEqual(1);
      expect(issues[0].field).assertEqual(ConnectionConfigField.TlsVersions);
      expect(issues[0].error.message).assertEqual('Unsupported TLS version: TLSv1.1');
      expect(issues[0].invalidValue).assertEqual('TLSv1.1');
    });

    it('ignoresDormantTlsValuesWhenTlsIsDisabled', 0, () => {
      const config = validConfig();
      config.ssl.mode = SslMode.DISABLED;
      config.ssl.clientCertPath = '/data/client.pem';
      config.ssl.tlsVersions = ['TLSv1.1'];

      expect(config.validateIssues().length).assertEqual(0);
    });

    it('keepsValidateEquivalentToIssueErrors', 0, () => {
      const config = new ConnectionConfig();
      config.port = Number.NaN;
      config.connectTimeoutMs = 1000.5;
      config.ssl.clientKeyPath = '/data/client-key.pem';
      config.ssl.tlsVersions = ['TLSv1.1'];

      const issues = config.validateIssues();
      const errors = config.validate();

      expect(errors.length).assertEqual(issues.length);
      for (let index = 0; index < issues.length; index++) {
        expect(errors[index].kind).assertEqual(issues[index].error.kind);
        expect(errors[index].message).assertEqual(issues[index].error.message);
      }
    });
  });
}

function validConfig(): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = '127.0.0.1';
  config.user = 'root';
  return config;
}
