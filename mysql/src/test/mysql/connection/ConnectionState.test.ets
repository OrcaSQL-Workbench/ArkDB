import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionState, ArkDbError, ArkDbErrorKind, MAX_QUERY_DRAIN_TIME_MS, MAX_STATEMENT_TIMEOUT_MS,
  QueryOptions
} from '@arkdb/core';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import {
  connectionStateAfterCommandFailure, remainingSynchronizationTimeMs, mysqlTlsRequested,
  synchronizationRefreshFailure
} from '../../../main/ets/mysql/MySqlConnection';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { validateQueryOptions } from '../../../main/ets/mysql/command/Query';

export default function connectionStateTest() {
  describe('connection command state', () => {
    it('keepsOnlyConsumedServerErrorsReadyAfterACommandWrite', 0, () => {
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Server))
        .assertEqual(ConnectionState.Ready);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Validation))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Network))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Protocol))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Cancelled))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Timeout))
        .assertEqual(ConnectionState.Error);
    });

    it('rejectsInvalidOptionsDuringPreflight', 0, () => {
      const options = new QueryOptions();
      options.maxRows = -1;
      let caught: ArkDbError | null = null;
      try {
        validateQueryOptions(options);
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
    });

    it('rejectsTimeoutsOutsideTheWorkerContract', 0, () => {
      const negative = new QueryOptions();
      negative.statementTimeoutMs = -1;
      expectValidation(negative);
      const excessive = new QueryOptions();
      excessive.statementTimeoutMs = MAX_STATEMENT_TIMEOUT_MS + 1;
      expectValidation(excessive);
      const excessiveDrain = new QueryOptions();
      excessiveDrain.maxDrainTimeMs = MAX_QUERY_DRAIN_TIME_MS + 1;
      expectValidation(excessiveDrain);
    });

    it('snapshotsValidatedOptionsBeforeAsyncExecution', 0, () => {
      const options = new QueryOptions();
      options.statementTimeoutMs = 15000;
      options.maxRows = 5000;
      options.maxResultBytes = 1024;
      options.maxDrainTimeMs = 7000;
      const snapshot = options.clone();

      options.maxRows = -1;
      options.maxResultBytes = 0;
      options.maxDrainTimeMs = 0;

      validateQueryOptions(snapshot);
      expect(snapshot.statementTimeoutMs).assertEqual(15000);
      expect(snapshot.maxRows).assertEqual(5000);
      expect(snapshot.maxResultBytes).assertEqual(1024);
      expect(snapshot.maxDrainTimeMs).assertEqual(7000);
    });

    it('usesOnlyTheRemainingSynchronizationBudgetForStatusRefresh', 0, () => {
      expect(remainingSynchronizationTimeMs(5100, 5000)).assertEqual(100);
      expect(remainingSynchronizationTimeMs(5000, 5000)).assertEqual(0);
      expect(remainingSynchronizationTimeMs(-1, 5000)).assertEqual(0);
    });

    it('poisonsTheConnectionWhenSynchronizationStatusRefreshFails', 0, () => {
      const failure = synchronizationRefreshFailure(
        ArkDbError.server('PING rejected', 1047, '08S01'));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(connectionStateAfterCommandFailure(failure.kind)).assertEqual(ConnectionState.Error);
    });

    it('honorsEverySslModeBeforeSendingCredentials', 0, () => {
      expect(mysqlTlsRequested(SslMode.DISABLED, Capabilities.SSL)).assertFalse();
      expect(mysqlTlsRequested(SslMode.PREFERRED, 0)).assertFalse();
      expect(mysqlTlsRequested(SslMode.PREFERRED, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.REQUIRED, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.VERIFY_CA, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.VERIFY_IDENTITY, Capabilities.SSL)).assertTrue();

      let error: ArkDbError | null = null;
      try {
        mysqlTlsRequested(SslMode.REQUIRED, 0);
      } catch (caught) {
        error = caught as ArkDbError;
      }
      expect(error !== null).assertTrue();
      expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
    });

    it('ignoresInactiveTlsFieldsWhenSslIsDisabled', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'localhost';
      config.user = 'root';
      config.ssl.mode = SslMode.DISABLED;
      config.ssl.clientCertPath = 'client.pem';
      config.ssl.tlsVersions = ['TLSv1.1'];
      expect(config.validate().length).assertEqual(0);

      config.ssl.mode = SslMode.REQUIRED;
      expect(config.validate().length).assertEqual(2);
    });

    it('normalizesTlsVersionsLikeTheTransport', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'example.mysql.database.azure.com';
      config.user = 'admin';
      config.ssl.mode = SslMode.VERIFY_CA;
      config.ssl.tlsVersions = ['TLSv1.2', ' TLSv1.3 ', ''];
      expect(config.validate().length).assertEqual(0);

      config.ssl.tlsVersions = [' TLSv1.1 '];
      expect(config.validate().length).assertEqual(1);
    });

    it('rejectsNonPositiveConnectTimeouts', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'localhost';
      config.user = 'root';
      config.connectTimeoutMs = 0;

      expect(config.validate().length).assertEqual(1);
    });
  });
}

function expectValidation(options: QueryOptions): void {
  let rejected = false;
  try {
    validateQueryOptions(options);
  } catch (error) {
    rejected = (error as ArkDbError).kind === ArkDbErrorKind.Validation;
  }
  expect(rejected).assertTrue();
}