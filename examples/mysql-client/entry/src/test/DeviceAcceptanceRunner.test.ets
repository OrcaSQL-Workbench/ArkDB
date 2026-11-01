import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionConfig, ConnectionReuse, ConnectionState,
  CoreDbExecutionController, DatabaseContext, DatabaseSessionStatus, DbConnectionFeatures,
  MySqlConnectionFeatures, MySqlParameter, MySqlPreparedExecutor,
  MySqlPreparedStatement, QueryCancellationResult, QueryOptions, QueryResult, QueryResultSink,
  QueryExecutionSummary, ServerFamily, MySqlServerInfo, SslMode
} from '@arkdb/mysql';
import {
  DeviceAcceptanceRequest
} from '../main/ets/sample/Messages';
import {
  DeviceEvidenceIdentity
} from '../main/ets/sample/DeviceEvidenceBinding';
import {
  DeviceAcceptanceConnection, DeviceAcceptanceFactory, DeviceAcceptanceRunner, DeviceDelay,
  DevicePlatformInfo, DevicePlatformReader
} from '../main/ets/sample/DeviceAcceptanceRunner';
import {
  DeviceReceiptSigner
} from '../main/ets/sample/DeviceReceiptSigner';

const SCHEMA_CHALLENGE: string = '33'.repeat(32);
const EXPECTED_CASES: string[] = [
  'tls_identity',
  'tls_hostname_mismatch',
  'server_error',
  'eof_protocol',
  'binary_protocol',
  'authorized_schema',
  'cancellation',
  'cleanup'
];

export default function deviceAcceptanceRunnerTest(): void {
  describe('Bound device acceptance runner', () => {
    it('signsOnePrivacySafeReceiptAfterEveryFixedCasePasses', 0, async () => {
      const factory = new FakeDeviceFactory();
      const binding = validBinding();
      factory.positive.challengeId = binding.challengeId;
      factory.positive.schemaChallenge = binding.schemaChallenge;
      const signer = new FakeSigner(binding.publicKeySpkiBase64);
      const request = validRequest();
      const response = await new DeviceAcceptanceRunner(
        factory, binding, new FakePlatformReader(), new ImmediateDelay(), signer
      ).run(request);

      expect(response.ok).assertTrue();
      expect(request.password).assertEqual('');
      expect(factory.configs.length).assertEqual(2);
      expect(factory.configs[0].ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
      expect(factory.configs[1].host).assertEqual('mismatch.synthetic.invalid');
      expect(factory.positive.closed).assertTrue();
      expect(factory.mismatch.closed).assertTrue();
      expect(response.serverVersion).assertEqual('8.0.36');
      expect(response.total).assertEqual(8);
      expect(response.passed).assertEqual(8);
      expect(response.failures).assertEqual(0);
      expect(response.errors).assertEqual(0);
      expect(response.ignored).assertEqual(0);
      expect(signer.payload.indexOf(binding.sourceCommit) >= 0).assertTrue();
      expect(signer.payload.indexOf(binding.artifactSha256) >= 0).assertTrue();
      expect(signer.payload.indexOf(request.signedHapSha256) >= 0).assertTrue();
      expect(signer.payload.indexOf(request.operatorEvidenceId) >= 0).assertTrue();
      expect(signer.payload.indexOf('"profile":"M1"') >= 0).assertTrue();
      expect(signer.payload.indexOf('"authPlugin":"caching_sha2_password"') >= 0).assertTrue();
      expect(signer.payload.indexOf('"tlsMode":"verify_identity"') >= 0).assertTrue();
      expect(signer.payload.indexOf('"startedAt":') >= 0).assertTrue();
      expect(signer.payload.indexOf('"completedAt":') >= 0).assertTrue();
      expect(signer.payload.indexOf('"durationMs":') >= 0).assertTrue();
      for (const id of EXPECTED_CASES) {
        expect(signer.payload.indexOf('"id":"' + id + '"') >= 0).assertTrue();
      }
      expect(response.receiptJson.indexOf('PRIVATE_')).assertEqual(-1);
      expect(response.receiptJson.indexOf(request.host)).assertEqual(-1);
      expect(response.receiptJson.indexOf(request.schema)).assertEqual(-1);
    });

    it('retainsCompleteFailedVerdictsWithoutLeakingConnectionInputs', 0, async () => {
      const factory = new FakeDeviceFactory();
      const binding = validBinding();
      factory.positive.challengeId = binding.challengeId;
      factory.positive.schemaChallenge = binding.schemaChallenge;
      factory.positive.serverInfo.tlsActive = false;
      const response = await new DeviceAcceptanceRunner(
        factory, binding, new FakePlatformReader(), new ImmediateDelay(),
        new FakeSigner(binding.publicKeySpkiBase64)
      ).run(validRequest());

      expect(response.ok).assertFalse();
      expect(response.total).assertEqual(8);
      expect(response.passed).assertEqual(7);
      expect(response.failures).assertEqual(1);
      expect(response.errors).assertEqual(0);
      expect(response.ignored).assertEqual(0);
      expect(response.receiptJson.indexOf('PRIVATE_')).assertEqual(-1);
    });

    it('rejectsGenericTlsFailureAsHostnameMismatchEvidence', 0, async () => {
      const factory = new FakeDeviceFactory();
      const binding = validBinding();
      factory.positive.challengeId = binding.challengeId;
      factory.positive.schemaChallenge = binding.schemaChallenge;
      factory.mismatch.mismatchCode = 'TLS_HANDSHAKE_FAILURE';
      const response = await new DeviceAcceptanceRunner(
        factory, binding, new FakePlatformReader(), new ImmediateDelay(),
        new FakeSigner(binding.publicKeySpkiBase64)
      ).run(validRequest());

      expect(response.ok).assertFalse();
      expect(response.total).assertEqual(8);
      expect(response.passed).assertEqual(7);
      expect(response.failures).assertEqual(1);
    });

    it('doesNotSignMariaDbAsMysqlProfileEvidence', 0, async () => {
      const factory = new FakeDeviceFactory();
      const binding = validBinding();
      factory.positive.challengeId = binding.challengeId;
      factory.positive.schemaChallenge = binding.schemaChallenge;
      factory.positive.serverInfo.family = ServerFamily.MariaDB;
      const response = await new DeviceAcceptanceRunner(
        factory, binding, new FakePlatformReader(), new ImmediateDelay(),
        new FakeSigner(binding.publicKeySpkiBase64)
      ).run(validRequest());

      expect(response.ok).assertFalse();
      expect(response.receiptJson).assertEqual('');
      expect(response.errorKind).assertEqual(ArkDbErrorKind.Validation);
    });

    it('rejectsTheCommittedUnboundHarnessBeforeCreatingAConnection', 0, async () => {
      const factory = new FakeDeviceFactory();
      const request = validRequest();
      const response = await new DeviceAcceptanceRunner(
        factory, new DeviceEvidenceIdentity(), new FakePlatformReader(), new ImmediateDelay(),
        new FakeSigner('')
      ).run(request);

      expect(response.ok).assertFalse();
      expect(response.receiptJson).assertEqual('');
      expect(response.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(factory.created).assertEqual(0);
      expect(request.password).assertEqual('');
    });

    it('clearsThePasswordWhenRuntimePlatformDiscoveryFails', 0, async () => {
      const request = validRequest();
      const response = await new DeviceAcceptanceRunner(
        new FakeDeviceFactory(), validBinding(), new FailingPlatformReader(), new ImmediateDelay(),
        new FakeSigner('')
      ).run(request);

      expect(response.ok).assertFalse();
      expect(response.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(response.text.indexOf('PRIVATE_')).assertEqual(-1);
      expect(request.password).assertEqual('');
    });
  });
}

function validRequest(): DeviceAcceptanceRequest {
  const request = new DeviceAcceptanceRequest();
  request.host = 'PRIVATE_HOST';
  request.mismatchHost = 'mismatch.synthetic.invalid';
  request.port = 3306;
  request.user = 'PRIVATE_USER';
  request.password = 'PRIVATE_PASSWORD';
  request.schema = 'PRIVATE_SCHEMA';
  request.caCertPath = 'PRIVATE_CA_PATH';
  request.profile = 'M1';
  request.features = '';
  request.signedHapSha256 = '99'.repeat(32);
  request.operatorEvidenceId = 'operator-evidence-001';
  return request;
}

function validBinding(): DeviceEvidenceIdentity {
  const binding = new DeviceEvidenceIdentity();
  binding.enabled = true;
  binding.challengeId = '11'.repeat(16);
  binding.receiptNonce = '22'.repeat(32);
  binding.schemaChallenge = SCHEMA_CHALLENGE;
  binding.createdAt = '2026-11-01T00:00:00.000Z';
  binding.expiresAt = '2026-11-02T00:00:00.000Z';
  binding.suiteId = 'arkdb.mysql.device-acceptance';
  binding.caseManifestSha256 = '44'.repeat(32);
  binding.releaseSetSha256 = '55'.repeat(32);
  binding.repository = 'OrcaSQL-Workbench/ArkDB';
  binding.driver = 'mysql';
  binding.packageName = '@arkdb/mysql';
  binding.version = '1.0.2';
  binding.sourceCommit = '66'.repeat(20);
  binding.artifactSha256 = '77'.repeat(32);
  binding.artifactByteLength = 230327;
  binding.sampleFingerprint = '88'.repeat(32);
  binding.publicKeySpkiBase64 =
    'MCowBQYDK2VwAyEADb/Cqqww74MVIcezIun9Mh1lbnx3cw9Qy9vYztWx2NA=';
  binding.publicKeySpkiSha256 = 'aa'.repeat(32);
  binding.privateKeyPkcs8Base64 =
    'MC4CAQAwBQYDK2VwBCIEIPFypge0/4Q4Nj+g3rdkq1waRD/wmRetRJ4eUBT0D86S';
  binding.format = 'bytecode-har';
  binding.compatibleSdkVersion = 24;
  binding.compatibleSdkType = 'HarmonyOS';
  binding.useNormalizedOHMUrl = true;
  binding.buildMode = 'release';
  return binding;
}

class FakePlatformReader implements DevicePlatformReader {
  read(): DevicePlatformInfo {
    const info = new DevicePlatformInfo();
    info.deviceType = 'tablet';
    info.sdkApiVersion = 24;
    info.osFullName = 'HarmonyOS 6.1.1';
    return info;
  }
}

class FailingPlatformReader implements DevicePlatformReader {
  read(): DevicePlatformInfo {
    throw new Error('PRIVATE_PLATFORM_FAILURE');
  }
}

class ImmediateDelay implements DeviceDelay {
  async wait(_milliseconds: number): Promise<void> {}
}

class FakeSigner implements DeviceReceiptSigner {
  payload: string = '';
  private publicKey: string;

  constructor(publicKey: string) {
    this.publicKey = publicKey;
  }

  async sign(payload: string): Promise<string> {
    this.payload = payload;
    return '{"schemaVersion":1,"kind":"arkdb-device-acceptance-envelope","payload":' +
      JSON.stringify(payload) + ',"signature":{"algorithm":"Ed25519","publicKeySpkiBase64":' +
      JSON.stringify(this.publicKey) + ',"valueBase64":"SYNTHETIC_SIGNATURE"}}';
  }
}

class FakeDeviceFactory implements DeviceAcceptanceFactory {
  readonly positive: FakeDeviceConnection = new FakeDeviceConnection(false);
  readonly mismatch: FakeDeviceConnection = new FakeDeviceConnection(true);
  configs: ConnectionConfig[] = [];
  created: number = 0;

  createConnection(config: ConnectionConfig, _password: string): DeviceAcceptanceConnection {
    this.configs.push(config.clone());
    return this.created++ === 0 ? this.positive : this.mismatch;
  }
}

class FakeDeviceConnection implements DeviceAcceptanceConnection {
  state: ConnectionState = ConnectionState.Idle;
  serverInfo: MySqlServerInfo = new MySqlServerInfo();
  sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  features: DbConnectionFeatures = new DbConnectionFeatures();
  mysqlFeatures: MySqlConnectionFeatures = new MySqlConnectionFeatures();
  closed: boolean = false;
  challengeId: string = '';
  schemaChallenge: string = '';
  mismatchCode: string = 'TLS_HOSTNAME_MISMATCH';
  private mismatch: boolean;
  private sleepReject: ((error: Error) => void) | null = null;

  constructor(mismatch: boolean) {
    this.mismatch = mismatch;
    this.serverInfo.family = ServerFamily.MySQL;
    this.serverInfo.version = '8.0.36';
    this.serverInfo.authPlugin = 'caching_sha2_password';
    this.serverInfo.tlsActive = true;
    this.serverInfo.capabilities = 0x01000000;
    this.features.cancellation = new FakeCancellation(this);
    this.mysqlFeatures.prepared = new FakePrepared(this);
  }

  async connect(): Promise<void> {
    if (this.mismatch) throw ArkDbError.tls('Synthetic hostname mismatch.', this.mismatchCode);
    this.state = ConnectionState.Ready;
  }

  async ping(): Promise<void> {
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    if (sql === 'SELECT SLEEP(10)') {
      this.state = ConnectionState.Querying;
      return new Promise<QueryResult>((_resolve, reject): void => { this.sleepReject = reject; });
    }
    if (sql.indexOf('required_missing_table') >= 0) {
      throw ArkDbError.server('Synthetic missing table.', 1146, '42S02');
    }
    const result = new QueryResult();
    result.rows = [[1]];
    return result;
  }

  interrupt(): void {
    const reject = this.sleepReject;
    this.sleepReject = null;
    this.state = ConnectionState.Ready;
    if (reject !== null) reject(ArkDbError.cancelled('Synthetic interruption.'));
  }

  async queryStream(_sql: string, _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.state = ConnectionState.Closed;
  }

  async changeContext(_context: DatabaseContext): Promise<void> {}
  async setAutocommit(_enabled: boolean): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async commit(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async rollback(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
}

class FakeCancellation implements CoreDbExecutionController {
  private connection: FakeDeviceConnection;

  constructor(connection: FakeDeviceConnection) {
    this.connection = connection;
  }

  async cancel(): Promise<QueryCancellationResult> {
    this.connection.interrupt();
    return new QueryCancellationResult(CancellationOutcome.Requested, ConnectionReuse.AwaitingCompletion);
  }

  isInterruptionError(error: ArkDbError): boolean {
    return error.kind === ArkDbErrorKind.Cancelled;
  }
}

class FakePrepared implements MySqlPreparedExecutor {
  private connection: FakeDeviceConnection;

  constructor(connection: FakeDeviceConnection) {
    this.connection = connection;
  }

  async execute(_sql: string, parameters: MySqlParameter[],
    _options?: QueryOptions): Promise<QueryResult> {
    const result = new QueryResult();
    if (parameters.length === 1 && parameters[0].value === this.connection.challengeId) {
      result.rows = [[this.connection.schemaChallenge]];
    } else if (parameters.length === 3) {
      result.rows = [[9007199254740993n, '12.34', new Uint8Array([0x00, 0x7f, 0xff])]];
    }
    return result;
  }

  async prepare(_sql: string): Promise<MySqlPreparedStatement> {
    throw ArkDbError.unsupported('Not needed by this fixture.');
  }

  async executeStream(_sql: string, _parameters: MySqlParameter[], _options: QueryOptions,
    _sink: QueryResultSink): Promise<QueryExecutionSummary> {
    throw ArkDbError.unsupported('Not needed by this fixture.');
  }
}
