import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionConfig,
  ConnectionConfigField,
  MySqlSessionOptions,
  ArkDbError,
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

    it('sessionValidationRejectsIllFormedStringsInStableOrder', 0, () => {
      const config = validConfig();
      config.session = sessionTextOptions('\uD800', '\uDC00');
      const issues = config.validateIssues();

      expect(issues.length).assertEqual(2);
      for (const issue of issues) {
        expect(issue.error instanceof ArkDbError).assertTrue();
        expect(issue.error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issue.invalidValue === undefined).assertTrue();
        expect(issue.error.message.indexOf('\uD800')).assertEqual(-1);
        expect(issue.error.message.indexOf('\uDC00')).assertEqual(-1);
      }
      expect(JSON.stringify(issues[0]).indexOf('"field":"session.timeZone"') >= 0).assertTrue();
      expect(JSON.stringify(issues[1]).indexOf('"field":"session.sqlMode"') >= 0).assertTrue();
      const errors = config.validate();
      expect(errors.length).assertEqual(2);
      for (let index = 0; index < errors.length; index++) {
        expect(errors[index].kind).assertEqual(issues[index].error.kind);
        expect(errors[index].message).assertEqual(issues[index].error.message);
      }
    });

    it('sessionCloneRejectsIllFormedStringsAndPreservesLegacyRules', 0, () => {
      const legacy = new ConnectionConfig();
      legacy.port = 0;
      legacy.connectTimeoutMs = 0;
      legacy.ssl.clientCertPath = 'fixture-client.pem';
      legacy.ssl.tlsVersions = ['TLSv1.1'];
      const legacyCopy = legacy.clone();
      expect(legacyCopy.host).assertEqual('');
      expect(legacyCopy.user).assertEqual('');
      expect(legacyCopy.port).assertEqual(0);
      expect(legacyCopy.connectTimeoutMs).assertEqual(0);
      expect(legacyCopy.ssl.clientCertPath).assertEqual('fixture-client.pem');
      for (const options of [sessionTextOptions('\uD800', ''), sessionTextOptions('', '\uDC00')]) {
        const config = validConfig();
        config.session = options;
        const failure = sessionCloneFailure(config);
        expect(failure !== null).assertTrue();
        if (failure !== null) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.message.indexOf('\uD800')).assertEqual(-1);
          expect(failure.message.indexOf('\uDC00')).assertEqual(-1);
        }
      }
    });

    it('sessionValidationKeepsExactWellFormedOptionsAndCloneIsolation', 0, () => {
      const absent = validConfig();
      expect(absent.validateIssues().length).assertEqual(0);
      expect(absent.clone().session === undefined).assertTrue();
      absent.session = new MySqlSessionOptions();
      expect(absent.validateIssues().length).assertEqual(0);
      const emptyCopy = absent.clone().session;
      expect(emptyCopy !== undefined && emptyCopy !== absent.session).assertTrue();
      if (emptyCopy === undefined) throw new Error('Expected cloned empty session options.');
      expect(JSON.stringify(emptyCopy)).assertEqual('{}');
      const fixtures: SessionTextFixture[] = [
        { timeZone: '', sqlMode: '' },
        { timeZone: ' Unknown/Session_Zone ', sqlMode: '' },
        { timeZone: '+08:00', sqlMode: 'ANSI_QUOTES' },
        { timeZone: 'Z'.repeat(1024), sqlMode: 'M'.repeat(1024) },
        { timeZone: " a'\\\u0000;\n\u8868\uD83D\uDE00 ", sqlMode: "'\"\\;\n" }
      ];
      for (const fixture of fixtures) {
        const config = validConfig();
        const options = sessionTextOptions(fixture.timeZone, fixture.sqlMode);
        config.session = options;
        expect(config.validateIssues().length).assertEqual(0);
        expect(config.validate().length).assertEqual(0);
        const copied = config.clone().session;
        expect(copied !== undefined && copied !== options).assertTrue();
        if (copied === undefined) throw new Error('Expected independently cloned session options.');
        expect(copied.timeZone).assertEqual(fixture.timeZone);
        expect(copied.sqlMode).assertEqual(fixture.sqlMode);
        options.timeZone = 'caller-mutated-zone';
        options.sqlMode = 'caller-mutated-mode';
        expect(copied.timeZone).assertEqual(fixture.timeZone);
        expect(copied.sqlMode).assertEqual(fixture.sqlMode);
        copied.timeZone = 'copy-mutated-zone';
        expect(options.timeZone).assertEqual('caller-mutated-zone');
      }
    });

    it('sessionIssuesAppendAfterLegacyValidationWithoutLeakingValues', 0, () => {
      const config = new ConnectionConfig();
      config.port = 0;
      config.connectTimeoutMs = 0;
      config.ssl.clientCertPath = 'fixture-client.pem';
      config.ssl.tlsVersions = ['TLSv1.1'];
      config.session = sessionTextOptions('private-session-payload-\uD800', 'private-session-payload-\uDC00');
      const issues = config.validateIssues();
      const oldFields = [ConnectionConfigField.Host, ConnectionConfigField.Port,
        ConnectionConfigField.User, ConnectionConfigField.ConnectTimeoutMs,
        ConnectionConfigField.ClientCredentials, ConnectionConfigField.TlsVersions];
      const oldMessages = ['Host is required', 'Port must be between 1 and 65535',
        'Username is required', 'Connect timeout must be a positive integer',
        'Client certificate and private key must be configured together', 'Unsupported TLS version: TLSv1.1'];
      expect(issues.length).assertEqual(8);
      for (let index = 0; index < oldFields.length; index++) {
        expect(issues[index].field).assertEqual(oldFields[index]);
        expect(issues[index].error.message).assertEqual(oldMessages[index]);
      }
      expect(JSON.stringify(issues[6]).indexOf('"field":"session.timeZone"') >= 0).assertTrue();
      expect(JSON.stringify(issues[7]).indexOf('"field":"session.sqlMode"') >= 0).assertTrue();
      for (const issue of issues.slice(6)) {
        expect(issue.error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issue.error.message.indexOf('private-session-payload')).assertEqual(-1);
        expect(issue.invalidValue === undefined).assertTrue();
      }
      const errors = config.validate();
      expect(errors.length).assertEqual(issues.length);
      for (let index = 0; index < errors.length; index++) {
        expect(errors[index].kind).assertEqual(issues[index].error.kind);
        expect(errors[index].message).assertEqual(issues[index].error.message);
      }
    });

    it('sessionJsonDtoAcceptsEmptyAndUnknownExtraFields', 0, () => {
      for (const source of ['{}', '{"extra":"not-a-driver-setting"}']) {
        const config = validConfig();
        config.session = sessionOptionsFromUntrustedJsonFixture(source);
        expect(config.validateIssues().length).assertEqual(0);
        const copied = config.clone().session;
        expect(copied !== undefined && copied !== config.session).assertTrue();
        if (copied === undefined) throw new Error('Expected cloned empty public session options.');
        expect(JSON.stringify(copied)).assertEqual('{}');
      }
      const config = validConfig();
      config.session = sessionOptionsFromUntrustedJsonFixture(
        '{"timeZone":"Unknown/Session_Zone","sqlMode":"","extra":7}');
      expect(config.validateIssues().length).assertEqual(0);
      const copied = config.clone().session;
      if (copied === undefined) throw new Error('Expected a cloned public session DTO.');
      expect(copied.timeZone).assertEqual('Unknown/Session_Zone');
      expect(copied.sqlMode).assertEqual('');
    });

    it('sessionJsonDtoRejectsMalformedOptionsWithCanonicalCloneErrors', 0, () => {
      const fixtures: SessionJsonFixture[] = [
        { source: 'null', fields: ['session'] },
        { source: '[]', fields: ['session'] },
        { source: '7', fields: ['session'] },
        { source: 'false', fields: ['session'] },
        { source: '"private-session-payload"', fields: ['session'] },
        { source: '{"timeZone":null}', fields: ['session.timeZone'] },
        { source: '{"timeZone":7}', fields: ['session.timeZone'] },
        { source: '{"timeZone":false}', fields: ['session.timeZone'] },
        { source: '{"timeZone":[]}', fields: ['session.timeZone'] },
        { source: '{"timeZone":{}}', fields: ['session.timeZone'] },
        { source: '{"sqlMode":null}', fields: ['session.sqlMode'] },
        { source: '{"sqlMode":7}', fields: ['session.sqlMode'] },
        { source: '{"sqlMode":false}', fields: ['session.sqlMode'] },
        { source: '{"sqlMode":[]}', fields: ['session.sqlMode'] },
        { source: '{"sqlMode":{}}', fields: ['session.sqlMode'] },
        { source: '{"timeZone":{"private":"private-session-payload"},"sqlMode":0}',
          fields: ['session.timeZone', 'session.sqlMode'] },
        { source: '{"timeZone":"private-session-payload-\\ud800"}', fields: ['session.timeZone'] }
      ];
      for (const fixture of fixtures) {
        const config = validConfig();
        config.session = sessionOptionsFromUntrustedJsonFixture(fixture.source);
        const issues = config.validateIssues();
        expect(issues.length).assertEqual(fixture.fields.length);
        for (let index = 0; index < issues.length; index++) {
          expect(issues[index].error.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(JSON.stringify(issues[index]).indexOf('"field":"' + fixture.fields[index] + '"') >= 0).assertTrue();
          expect(issues[index].invalidValue === undefined).assertTrue();
          expect(issues[index].error.message.indexOf('private-session-payload')).assertEqual(-1);
        }
        const failure = sessionCloneFailure(config);
        expect(failure !== null).assertTrue();
        if (failure !== null) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.message.indexOf('private-session-payload')).assertEqual(-1);
        }
      }
    });

    it('preparedCacheAcceptsMissingZeroAndIntegerBounds', 0, () => {
      const absent = validConfig();
      expect(absent.preparedCacheSize === undefined).assertTrue();
      expect(absent.validateIssues().length).assertEqual(0);
      expect(absent.clone().preparedCacheSize === undefined).assertTrue();
      for (const capacity of [0, 1, 256]) {
        const config = validConfig();
        config.preparedCacheSize = capacity;
        expect(config.validateIssues().length).assertEqual(0);
        expect(config.validate().length).assertEqual(0);
        expect(config.clone().preparedCacheSize).assertEqual(capacity);
      }
    });

    it('preparedCacheRejectsInvalidNumericSizesBeforeClone', 0, () => {
      const invalid: number[] = [-1, -0.5, 0.5, 256.5, 257, 9007199254740992,
        Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY];
      for (const capacity of invalid) {
        const config = validConfig();
        config.preparedCacheSize = capacity;
        const issues = config.validateIssues();
        const errors = config.validate();
        expect(issues.length).assertEqual(1);
        expect(issues[0].field).assertEqual(ConnectionConfigField.PreparedCacheSize);
        expect(issues[0].error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issues[0].invalidValue === undefined).assertTrue();
        expect(errors.length).assertEqual(1);
        expect(errors[0].kind).assertEqual(ArkDbErrorKind.Validation);
        expect(errors[0].message).assertEqual(issues[0].error.message);
        const failure = sessionCloneFailure(config);
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Invalid cache capacity must not be cloned.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.message).assertEqual(issues[0].error.message);
      }
    });

    it('preparedCacheRejectsMalformedJsonValuesWithoutCoercion', 0, () => {
      const values: string[] = ['null', 'true', 'false', '"1"', '""',
        '"private-cache-value"', '[]', '{}', '{"private":"private-cache-value"}'];
      for (const value of values) {
        const input = cacheConfigFromUntrustedJsonFixture('{"preparedCacheSize":' + value + '}');
        const config = validConfig();
        config.preparedCacheSize = input.preparedCacheSize;
        const issues = config.validateIssues();
        expect(issues.length).assertEqual(1);
        expect(issues[0].field).assertEqual(ConnectionConfigField.PreparedCacheSize);
        expect(issues[0].error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issues[0].invalidValue === undefined).assertTrue();
        expect(issues[0].error.message.indexOf('private-cache-value')).assertEqual(-1);
        const failure = sessionCloneFailure(config);
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Malformed cache capacity must not be cloned.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.message).assertEqual(issues[0].error.message);
      }
    });

    it('preparedCacheIssuesAppendWithoutChangingExistingValidationOrder', 0, () => {
      const config = new ConnectionConfig();
      config.session = sessionOptionsFromUntrustedJsonFixture('{"timeZone":null}');
      config.preparedCacheSize = -1;
      const issues = config.validateIssues();
      const fields: ConnectionConfigField[] = [ConnectionConfigField.Host, ConnectionConfigField.User,
        ConnectionConfigField.SessionTimeZone, ConnectionConfigField.PreparedCacheSize];
      expect(issues.length).assertEqual(4);
      const errors = config.validate();
      expect(errors.length).assertEqual(4);
      for (let index = 0; index < fields.length; index += 1) {
        expect(issues[index].field).assertEqual(fields[index]);
        expect(errors[index].kind).assertEqual(ArkDbErrorKind.Validation);
        expect(errors[index].message).assertEqual(issues[index].error.message);
      }
      const failure = sessionCloneFailure(config);
      expect(failure !== null).assertTrue();
      if (failure === null) throw new Error('Invalid session/cache options must not be cloned.');
      expect(failure.message).assertEqual(issues[2].error.message);
    });

    it('preparedCacheCloneKeepsAnIndependentCapacitySnapshot', 0, () => {
      const config = validConfig();
      config.preparedCacheSize = 1;
      const copy = config.clone();
      config.preparedCacheSize = 256;
      expect(copy.preparedCacheSize).assertEqual(1);
      copy.preparedCacheSize = 0;
      expect(config.preparedCacheSize).assertEqual(256);
      expect(copy.validateIssues().length).assertEqual(0);
      expect(config.validateIssues().length).assertEqual(0);
    });
  });
}

function validConfig(): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = '127.0.0.1';
  config.user = 'root';
  return config;
}

interface SessionTextFixture {
  timeZone: string;
  sqlMode: string;
}

interface SessionJsonFixture {
  source: string;
  fields: string[];
}

function sessionTextOptions(timeZone: string, sqlMode: string): MySqlSessionOptions {
  const options = new MySqlSessionOptions();
  options.timeZone = timeZone;
  options.sqlMode = sqlMode;
  return options;
}

function sessionCloneFailure(config: ConnectionConfig): ArkDbError | null {
  try {
    config.clone();
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  }
  return null;
}

function sessionOptionsFromUntrustedJsonFixture(source: string): MySqlSessionOptions {
  return JSON.parse(source) as MySqlSessionOptions;
}

function cacheConfigFromUntrustedJsonFixture(source: string): ConnectionConfig {
  return JSON.parse(source) as ConnectionConfig;
}
