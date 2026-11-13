import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnection } from '../../../main/ets/pgsql/PostgresConnection';
import { PostgresAuthPlatform, PostgresScramPort, strictUtf8Decode, strictUtf8Encode } from '../../../main/ets/pgsql/auth/PostgresAuthCrypto';
import { createDefaultPostgresStartupRunner } from '../../../main/ets/pgsql/command/PostgresStartup';
import { PostgresLifecycleTransport } from '../../../main/ets/pgsql/connection/PostgresConnectionLifecycle';
import { applyPostgresParameterStatus, postgresErrorFromResponse } from '../../../main/ets/pgsql/execution/PostgresSettlements';
import { PostgresConnectionConfig, PostgresSslConfig, PostgresSslMode } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
import { PostgresError, PostgresServerInfo, PostgresTransactionState } from '../../../main/ets/pgsql/model/PostgresModels';
import { PostgresDiagnosticFields, PostgresErrorResponse, PostgresParameterStatus } from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';
import { PostgresTcpSocket, PostgresTcpSocketFactory, PostgresTcpTransport, PostgresTlsSocket } from '../../../main/ets/pgsql/transport/PostgresTcpTransport';
const RFC_NONCE: string = 'rOprNGfwEbeRWgbNEkqO';
const RFC_SERVER_NONCE: string = 'rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0';
const RFC_SERVER_FIRST: string = 'r=' + RFC_SERVER_NONCE + ',s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096';
const RFC_CLIENT_FINAL: string = 'c=biws,r=' + RFC_SERVER_NONCE + ',p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=';
const RFC_SERVER_FINAL: string = 'v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=';
export default function postgresStartupTest(): void {
  describe('PostgresStartup', () => {
    it('completesPlaintextTrustStartupPopulatingServerInfoBackendKeyAndSessionStatus', 0, async () => {
      const socket = new ScriptedSocket([concatFrames([
        msgNotice('NOTICE', '00000', 'welcome-do-not-log'), msgAuthOk(), msgParam('server_version', '16.4 (Harmony)'),
        msgParam('server_encoding', 'UTF8'), msgParam('client_encoding', 'UTF8'), msgParam('integer_datetimes', 'off'),
        msgParam('DateStyle', 'ISO, MDY'), msgParam('TimeZone', 'UTC'), msgParam('custom_extension.flag', 'ignored'),
        msgBackendKey(4242, [0x12, 0x34, 0x56, 0x78]), msgNotification(99, 'boot_chan', 'secret_payload'), msgReady(0x49)
      ])]);
      const cfg = baseConfig(PostgresSslMode.DISABLED); cfg.user = 'alice';
      const conn = new PostgresConnection(cfg, '', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(socket));
      await expectOk((): Promise<void> => conn.connect());
      expect(conn.state === ConnectionState.Ready && !conn.serverInfo.tlsActive && conn.serverInfo.driverId === 'pgsql' &&
        conn.serverInfo.productName === 'PostgreSQL' && conn.serverInfo.version === '16.4 (Harmony)' && conn.serverInfo.serverEncoding === 'UTF8' &&
        conn.serverInfo.defaultEncoding === 'UTF8' && !conn.serverInfo.integerDatetimes && conn.serverInfo.dateStyle === 'ISO, MDY' &&
        conn.serverInfo.timeZone === 'UTC' && conn.serverInfo.backendProcessId === 4242 && conn.serverInfo.connectionHandle === '4242' &&
        conn.sessionStatus.known && conn.sessionStatus.autocommit && !conn.sessionStatus.inTransaction &&
        conn.sessionStatus.transactionState === PostgresTransactionState.Idle && !socket.tlsUpgraded).assertTrue();
      assertBytes(socket.tcpWrites[0], expectedStartupFrame('alice', 'alice', 'arkdb'));
      await conn.close();
      expect(conn.state === ConnectionState.Closed && socket.tcpWrites.length === 2).assertTrue();
      assertBytes(socket.tcpWrites[1], [0x58, 0x00, 0x00, 0x00, 0x04]);
      const emptyDbSocket = new ScriptedSocket([concatFrames([msgAuthOk(), msgParam('integer_datetimes', 'on'), msgReady(0x49)])]);
      const emptyDbCfg = baseConfig(PostgresSslMode.DISABLED); emptyDbCfg.user = 'bob'; emptyDbCfg.database = '';
      const emptyDbConn = new PostgresConnection(emptyDbCfg, '', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(emptyDbSocket));
      await expectOk((): Promise<void> => emptyDbConn.connect());
      expect(emptyDbConn.serverInfo.integerDatetimes).assertTrue();
      assertBytes(emptyDbSocket.tcpWrites[0], expectedStartupFrame('bob', 'bob', 'arkdb'));
      await emptyDbConn.close();
    });
    it('negotiatesTlsScramSha256AndRejectsSkippedSaslFinalOrOutOfOrderChallenges', 0, async () => {
      const scramRunner = createDefaultPostgresStartupRunner(new StubAuthPlatform(), (): PostgresScramPort => new RfcScramPort());
      const socket = new ScriptedSocket([new Uint8Array([0x53])], [
        msgAuthSasl(['SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256']), msgAuthSaslContinue(RFC_SERVER_FIRST),
        concatFrames([msgAuthSaslFinal(RFC_SERVER_FINAL), msgAuthOk(), msgParam('client_encoding', 'UTF8'), msgReady(0x54)])
      ]);
      const cfg = baseConfig(PostgresSslMode.VERIFY_FULL); cfg.user = 'user'; cfg.database = 'appdb';
      const conn = new PostgresConnection(cfg, 'pencil', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(socket), scramRunner);
      await expectOk((): Promise<void> => conn.connect());
      expect(conn.state === ConnectionState.Ready && conn.serverInfo.tlsActive && socket.tlsUpgraded && socket.peerVerified &&
        conn.sessionStatus.inTransaction && conn.sessionStatus.transactionState === PostgresTransactionState.InTransaction).assertTrue();
      assertBytes(socket.tcpWrites[0], [0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f]);
      assertBytes(socket.tlsWrites[0], expectedStartupFrame('user', 'appdb', 'arkdb'));
      assertBytes(socket.tlsWrites[1], expectedSaslInitialFrame('SCRAM-SHA-256', 'n,,n=user,r=' + RFC_NONCE));
      assertBytes(socket.tlsWrites[2], expectedSaslResponseFrame(RFC_CLIENT_FINAL));
      await conn.close();
      const rogueSkipFinal = new ScriptedSocket([new Uint8Array([0x53])], [msgAuthSasl(['SCRAM-SHA-256']), concatFrames([msgAuthSaslContinue(RFC_SERVER_FIRST), msgAuthOk(), msgReady(0x49)])]);
      const rogueConn = new PostgresConnection(cfg, 'pencil', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(rogueSkipFinal), scramRunner);
      expect((await asyncFail((): Promise<void> => rogueConn.connect())).kind).assertEqual(ArkDbErrorKind.Auth);
      expect(rogueConn.state).assertEqual(ConnectionState.Error);
      const rogueSkipAuthOk = new ScriptedSocket([new Uint8Array([0x53])], [msgAuthSasl(['SCRAM-SHA-256']), msgAuthSaslContinue(RFC_SERVER_FIRST), concatFrames([msgAuthSaslFinal(RFC_SERVER_FINAL), msgReady(0x49)])]);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(cfg, 'pencil', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(rogueSkipAuthOk), scramRunner).connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      const pausedPort = new PausedScramPort();
      const raceScramRunner = createDefaultPostgresStartupRunner(new StubAuthPlatform(), (): PostgresScramPort => pausedPort);
      const raceScramCfg = baseConfig(PostgresSslMode.DISABLED); raceScramCfg.user = 'user';
      const raceScramConn = new PostgresConnection(raceScramCfg, 'pencil', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([msgAuthSasl(['SCRAM-SHA-256']), msgAuthSaslContinue(RFC_SERVER_FIRST)])), raceScramRunner);
      const pendingScramConnect = raceScramConn.connect();
      await pausedPort.deriveEntered; await raceScramConn.close();
      expect((await asyncFail((): Promise<void> => pendingScramConnect)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      pausedPort.releaseDerive(); await flushTicks(20); expect(pausedPort.hmacAfterDispose).assertEqual(0);
      const pausedDefault = new PausedDefaultPbkdf2Platform();
      const defaultScramConn = new PostgresConnection(raceScramCfg, 'p'.repeat(70), new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([msgAuthSasl(['SCRAM-SHA-256']), msgAuthSaslContinue('r=AAECAwQFBgcICQoLDA0ODxARsrv,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096')])), createDefaultPostgresStartupRunner(pausedDefault));
      const pendingDefaultScram = defaultScramConn.connect();
      await pausedDefault.entered; await defaultScramConn.close();
      expect((await asyncFail((): Promise<void> => pendingDefaultScram)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      pausedDefault.release(); await flushTicks(25);
      expect(pausedDefault.hmacCalls).assertEqual(1); assertZeroed(pausedDefault.firstShaRef!); assertZeroed(pausedDefault.firstKeyRef!);
      const emptyScramSock = new ScriptedSocket([msgAuthSasl(['SCRAM-SHA-256'])]);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(raceScramCfg, '', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(emptyScramSock), scramRunner).connect())).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(emptyScramSock.tcpWrites.length).assertEqual(1);
      for (const badSeq of [[msgAuthSaslContinue(RFC_SERVER_FIRST)], [msgAuthSaslFinal(RFC_SERVER_FINAL)],
        [msgAuthSasl(['SCRAM-SHA-256']), msgAuthSaslFinal(RFC_SERVER_FINAL)], [msgAuthSasl(['SCRAM-SHA-256']), msgAuthCleartext()]]) {
        expect((await asyncFail((): Promise<void> => new PostgresConnection(raceScramCfg, 'pencil', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket(badSeq)), scramRunner).connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
    });

    it('authenticatesDeprecatedMd5AndEnforcesControlledCleartextSingleNulFrames', 0, async () => {
      const md5Runner = createDefaultPostgresStartupRunner(new StubAuthPlatform());
      const md5Sock = new ScriptedSocket([msgAuthMd5([0x12, 0x34, 0x56, 0x78]), concatFrames([msgAuthOk(), msgReady(0x49)])]);
      const md5Cfg = baseConfig(PostgresSslMode.DISABLED); md5Cfg.user = 'user';
      const md5Conn = new PostgresConnection(md5Cfg, 'password', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(md5Sock), md5Runner);
      await expectOk((): Promise<void> => md5Conn.connect());
      const expectedMd5Frame = new Uint8Array(41);
      expectedMd5Frame[0] = 0x70; new DataView(expectedMd5Frame.buffer).setInt32(1, 40, false);
      expectedMd5Frame.set(strictUtf8Encode('md5d6f407104ca5ba8553d598fed7df90e0'), 5); expectedMd5Frame[40] = 0x00;
      assertBytes(md5Sock.tcpWrites[1], expectedMd5Frame); assertZeroed(md5Sock.rawTcpWriteRefs[1]);
      await md5Conn.close();
      const pausedMd5 = new PausedMd5Platform();
      const raceMd5Conn = new PostgresConnection(md5Cfg, 'password', new PassiveTimers(),
        (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([msgAuthMd5([0x12, 0x34, 0x56, 0x78])])), createDefaultPostgresStartupRunner(pausedMd5));
      const pendingMd5 = raceMd5Conn.connect();
      await pausedMd5.entered; await raceMd5Conn.close();
      expect((await asyncFail((): Promise<void> => pendingMd5)).kind).assertEqual(ArkDbErrorKind.Cancelled);
      pausedMd5.release(); await flushTicks(20);
      const clockTimers = new PassiveTimers(); const postExpiryCfg = baseConfig(PostgresSslMode.DISABLED);
      postExpiryCfg.user = 'user'; postExpiryCfg.connectTimeoutMs = 500;
      const postExpirySock = new ScriptedSocket([msgAuthSasl(['SCRAM-SHA-256']), msgAuthSaslContinue(RFC_SERVER_FIRST)]);
      const postExpiryConn = new PostgresConnection(postExpiryCfg, 'pencil', clockTimers, (): PostgresLifecycleTransport => wrapTcp(postExpirySock),
        createDefaultPostgresStartupRunner(new StubAuthPlatform(), (): PostgresScramPort => new PostExpiryScramPort(clockTimers)));
      expect((await asyncFail((): Promise<void> => postExpiryConn.connect())).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(postExpirySock.tcpWrites.length).assertEqual(2);
      const emptyMd5Sock = new ScriptedSocket([msgAuthMd5([0x12, 0x34, 0x56, 0x78])]);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(md5Cfg, '', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(emptyMd5Sock), md5Runner).connect())).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(emptyMd5Sock.tcpWrites.length).assertEqual(1);
      const socket = new ScriptedSocket([new Uint8Array([0x53])], [concatFrames([msgAuthCleartext(), msgAuthOk(), msgParam('client_encoding', 'UTF8'), msgReady(0x49)])]);
      const cfg = baseConfig(PostgresSslMode.VERIFY_FULL);
      cfg.user = 'carol'; cfg.database = 'analytics'; cfg.applicationName = ''; cfg.allowCleartextPassword = true;
      const conn = new PostgresConnection(cfg, 's3cr3t', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(socket));
      await expectOk((): Promise<void> => conn.connect());
      expect(conn.state === ConnectionState.Ready && conn.serverInfo.tlsActive && socket.tlsUpgraded && socket.peerVerified).assertTrue();
      assertBytes(socket.tcpWrites[0], [0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f]);
      assertBytes(socket.tlsWrites[0], expectedStartupFrame('carol', 'analytics', ''));
      assertBytes(socket.tlsWrites[1], [0x70, 0x00, 0x00, 0x00, 0x0b, 0x73, 0x33, 0x63, 0x72, 0x33, 0x74, 0x00]);
      assertZeroed(socket.rawTlsWriteRefs[1]);
      await conn.close();
      const failWriteSock = new ScriptedSocket([new Uint8Array([0x53])], [msgAuthCleartext()]); failWriteSock.failTlsSendAt = 2;
      expect((await asyncFail((): Promise<void> => new PostgresConnection(cfg, 's3cr3t', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(failWriteSock)).connect())).kind).assertEqual(ArkDbErrorKind.Tls);
      assertZeroed(failWriteSock.rawTlsWriteRefs[1]);
      for (const badMode of [PostgresSslMode.DISABLED, PostgresSslMode.REQUIRED, PostgresSslMode.VERIFY_CA]) {
        const modeSocket = badMode === PostgresSslMode.DISABLED ? new ScriptedSocket([msgAuthCleartext()]) : new ScriptedSocket([new Uint8Array([0x53])], [msgAuthCleartext()]);
        const modeCfg = baseConfig(badMode); modeCfg.allowCleartextPassword = true;
        const modeConn = new PostgresConnection(modeCfg, 's3cr3t', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(modeSocket));
        expect((await asyncFail((): Promise<void> => modeConn.connect())).kind).assertEqual(badMode === PostgresSslMode.DISABLED ? ArkDbErrorKind.Auth : ArkDbErrorKind.Unsupported);
        expect(modeConn.state).assertEqual(ConnectionState.Error);
      }
      expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.VERIFY_FULL), 's3cr3t', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([new Uint8Array([0x53])], [msgAuthCleartext()]))).connect())).kind).assertEqual(ArkDbErrorKind.Unsupported);
      const emptyPwSocket = new ScriptedSocket([new Uint8Array([0x53])], [msgAuthCleartext()]);
      const emptyPwCfg = baseConfig(PostgresSslMode.VERIFY_FULL); emptyPwCfg.allowCleartextPassword = true;
      expect((await asyncFail((): Promise<void> => new PostgresConnection(emptyPwCfg, '', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(emptyPwSocket)).connect())).kind).assertEqual(ArkDbErrorKind.Validation);
      expect(emptyPwSocket.tlsWrites.length).assertEqual(1);
    });

    it('failsClosedOnSslRejectionStuffedBytesUnsupportedAuthNegotiationAndServerErrors', 0, async () => {
      const noTls = new ScriptedSocket([new Uint8Array([0x4e])]);
      const noTlsErr = await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.REQUIRED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(noTls)).connect());
      expect(noTlsErr.kind === ArkDbErrorKind.Tls && noTlsErr.nativeCode === 'SSL_NOT_SUPPORTED' && !noTls.tlsUpgraded).assertTrue();
      const preTlsErrSock = new ScriptedSocket([new Uint8Array([0x45, 0x00, 0x00, 0x00, 0x10])]);
      const preTlsErr = await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.VERIFY_FULL), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(preTlsErrSock)).connect());
      expect(preTlsErr.kind === ArkDbErrorKind.Tls && preTlsErr.nativeCode === 'SSL_PRE_TLS_ERROR' && !preTlsErrSock.tlsUpgraded).assertTrue();
      expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.REQUIRED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => new NullReadTransport()).connect())).kind).assertEqual(ArkDbErrorKind.Tls);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.REQUIRED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([new Uint8Array([0x3f])]))).connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      const stuffedAfterS = new ScriptedSocket([new Uint8Array([0x53, 0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00])]);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.VERIFY_FULL), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(stuffedAfterS)).connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(!stuffedAfterS.tlsUpgraded).assertTrue();
      for (const unsupportedFrame of [msgAuthCode(2), msgAuthCode(7), backendFrame(0x52, [0, 0, 0, 8, 1]), msgAuthCode(9), backendFrame(0x52, [0, 0, 0, 99]), msgAuthSasl(['SCRAM-SHA-256-PLUS']), msgNegotiate(0, ['_pq_.custom'])]) {
        expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.DISABLED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([unsupportedFrame]))).connect())).kind).assertEqual(ArkDbErrorKind.Unsupported);
      }
      for (const badProtoFrames of [concatFrames([msgParam('server_version', '16.4')]), concatFrames([msgBackendKey(1, [9, 9, 9, 9])]), concatFrames([backendFrame(0x4b, [1, 2, 3])]), concatFrames([msgReady(0x49)]),
        concatFrames([msgAuthOk(), backendFrame(0x4b, [0, 0, 0, 1, 9, 9, 9, 9, 0xaa])]), concatFrames([msgAuthOk(), msgParam('client_encoding', 'LATIN1'), msgReady(0x49)]), concatFrames([msgAuthOk(), msgParam('integer_datetimes', 'maybe'), msgReady(0x49)]),
        concatFrames([msgAuthOk(), msgBackendKey(1, [1, 2, 3, 4]), msgBackendKey(2, [5, 6, 7, 8]), msgReady(0x49)]),
        concatFrames([msgAuthOk(), backendFrame(0x49, []), msgReady(0x49)]), concatFrames([msgAuthOk(), msgAuthOk(), msgReady(0x49)])]) {
        expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.DISABLED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([badProtoFrames]))).connect())).kind).assertEqual(ArkDbErrorKind.Protocol);
      }
      const authErr = await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.DISABLED), 'pw', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(new ScriptedSocket([msgError('FATAL', 'FATAL', '28P01', 'password authentication failed')]))).connect());
      expect(authErr instanceof PostgresError && authErr.kind === ArkDbErrorKind.Auth && authErr.sqlState === '28P01' && authErr.nativeCode === '28P01' && authErr.code === undefined).assertTrue();
      const dbErrSock = new ScriptedSocket([concatFrames([msgAuthOk(), msgParam('server_version', '16.4'), msgBackendKey(777, [1, 2, 3, 4]), msgError('FATAL', 'FATAL', '3D000', 'database does not exist')])]);
      const dbErrConn = new PostgresConnection(baseConfig(PostgresSslMode.DISABLED), 'pw-scrub-me', new PassiveTimers(), (): PostgresLifecycleTransport => wrapTcp(dbErrSock));
      const dbErr = await asyncFail((): Promise<void> => dbErrConn.connect());
      expect(dbErr instanceof PostgresError && dbErr.kind === ArkDbErrorKind.Server && dbErr.sqlState === '3D000' && dbErrConn.state === ConnectionState.Error &&
        dbErrConn.serverInfo.version === '' && dbErrConn.serverInfo.backendProcessId === 0 && JSON.stringify(dbErrConn).indexOf('pw-scrub-me') === -1).assertTrue();
      const fields = new PostgresDiagnosticFields();
      fields.localizedSeverity = 'ERREUR'; fields.severity = 'ERROR'; fields.sqlState = '23505'; fields.message = 'dup';
      fields.detail = 'dt'; fields.hint = 'ht'; fields.position = '0'; fields.internalPosition = '9007199254740991';
      fields.internalQuery = 'SELECT 1'; fields.where = 'ctx'; fields.schemaName = 'public'; fields.tableName = 'users';
      fields.columnName = 'email'; fields.dataTypeName = 'text'; fields.constraintName = 'users_email_key';
      fields.sourceFile = 'nbtinsert.c'; fields.sourceLine = '42'; fields.sourceRoutine = '_bt_check_unique';
      const mapped = postgresErrorFromResponse(new PostgresErrorResponse(fields));
      expect(mapped.kind === ArkDbErrorKind.Server && mapped.severity === 'ERROR' && mapped.localizedSeverity === 'ERREUR' &&
        mapped.sqlState === '23505' && mapped.nativeCode === '23505' && mapped.code === undefined && mapped.detail === 'dt' && mapped.hint === 'ht' &&
        mapped.position === 0 && mapped.internalPosition === 9007199254740991 && mapped.internalQuery === 'SELECT 1' && mapped.where === 'ctx' &&
        mapped.schemaName === 'public' && mapped.tableName === 'users' && mapped.columnName === 'email' && mapped.dataTypeName === 'text' &&
        mapped.constraintName === 'users_email_key' && mapped.sourceFile === 'nbtinsert.c' && mapped.sourceLine === 42 && mapped.sourceRoutine === '_bt_check_unique').assertTrue();
      const fallbackFields = new PostgresDiagnosticFields();
      fallbackFields.localizedSeverity = 'FATAL'; fallbackFields.sqlState = '28000'; fallbackFields.message = 'denied';
      fallbackFields.position = '01'; fallbackFields.internalPosition = '9007199254740992'; fallbackFields.sourceLine = '-5';
      const fallbackErr = postgresErrorFromResponse(new PostgresErrorResponse(fallbackFields));
      expect(fallbackErr.kind === ArkDbErrorKind.Auth && fallbackErr.severity === 'FATAL' && fallbackErr.localizedSeverity === 'FATAL' &&
        fallbackErr.position === undefined && fallbackErr.internalPosition === undefined && fallbackErr.sourceLine === undefined).assertTrue();
      const subViewChunk = new Uint8Array([0xff, 0x52, 0, 0, 0, 8, 0, 0, 0, 0, 0x4b, 0, 0, 0, 12, 0, 0, 0, 7, 1, 2, 3, 4, 0x5a, 0, 0, 0, 5, 0x49, 0xee]);
      const subViewTp = new SubarrayChunkTransport([subViewChunk.subarray(1, 6), subViewChunk.subarray(6, 10), subViewChunk.subarray(10, 15), subViewChunk.subarray(15, 20), subViewChunk.subarray(20, 23), subViewChunk.subarray(23, 28), subViewChunk.subarray(28, 29)]);
      const subViewConn = new PostgresConnection(baseConfig(PostgresSslMode.DISABLED), '', new PassiveTimers(), (): PostgresLifecycleTransport => subViewTp);
      await expectOk((): Promise<void> => subViewConn.connect());
      assertZeroed(subViewChunk.subarray(1, 29));
      await subViewConn.close();
      const oversizeBacking = new Uint8Array([0xfe, 0xaa, 0xbb, 0xcc, 0xfd]);
      const badChunkTp = new SubarrayChunkTransport([oversizeBacking.subarray(1, 4)]);
      expect((await asyncFail((): Promise<void> => new PostgresConnection(baseConfig(PostgresSslMode.REQUIRED), '', new PassiveTimers(), (): PostgresLifecycleTransport => badChunkTp).connect())).kind).assertEqual(ArkDbErrorKind.Tls);
      assertZeroed(oversizeBacking.subarray(1, 4));
      expect(oversizeBacking[0] === 0xfe && oversizeBacking[4] === 0xfd).assertTrue();
      const info = new PostgresServerInfo(); applyPostgresParameterStatus(info, new PostgresParameterStatus('server_version', '17.1')); expect(info.version).assertEqual('17.1');
    });
  });
}

function baseConfig(mode: PostgresSslMode): PostgresConnectionConfig { const cfg = new PostgresConnectionConfig(); cfg.host = 'pg.example.internal'; cfg.user = 'postgres'; cfg.ssl.mode = mode; return cfg; }
function wrapTcp(socket: ScriptedSocket): PostgresLifecycleTransport { return new WrappedTcpTransport(new PostgresTcpTransport(new SingleSocketFactory(socket), undefined, new PassiveTimers())); }
class WrappedTcpTransport implements PostgresLifecycleTransport {
  private readonly inner: PostgresTcpTransport; constructor(inner: PostgresTcpTransport) { this.inner = inner; }
  connect(h: string, p: number, t: number): Promise<void> { return this.inner.connect(h, p, t); }
  prepareTlsUpgrade(): void { this.inner.prepareTlsUpgrade(); }
  upgradeToTls(h: string, p: number, c: PostgresSslConfig, t: number): Promise<void> { return this.inner.upgradeToTls(h, p, c, t); }
  read(m: number): Promise<Uint8Array | null> { return this.inner.read(m); }
  write(d: Uint8Array): Promise<number> { return this.inner.write(d); }
  close(): Promise<void> { return this.inner.close(); } abort(e: ArkDbError): Promise<void> { return this.inner.abort(e); }
}
class SingleSocketFactory implements PostgresTcpSocketFactory { private readonly s: ScriptedSocket; constructor(s: ScriptedSocket) { this.s = s; } create(): PostgresTcpSocket { return this.s; } }
class ScriptedSocket implements PostgresTcpSocket, PostgresTlsSocket {
  readonly tcpWrites: Uint8Array[] = []; readonly tlsWrites: Uint8Array[] = [];
  readonly rawTcpWriteRefs: Uint8Array[] = []; readonly rawTlsWriteRefs: Uint8Array[] = [];
  tlsUpgraded: boolean = false; peerVerified: boolean = false; failTlsSendAt: number = 0;
  private readonly tcpReplies: Uint8Array[]; private readonly tlsReplies: Uint8Array[];
  private onTcpMsg: ((d: Uint8Array) => void) | null = null; private onTlsMsg: ((d: Uint8Array) => void) | null = null;
  constructor(tcpReplies: Uint8Array[], tlsReplies: Uint8Array[] = []) { this.tcpReplies = tcpReplies.slice(); this.tlsReplies = tlsReplies.slice(); }
  listen(msg: (d: Uint8Array) => void, _c: () => void, _e: (f: Object) => void): void { if (!this.tlsUpgraded) this.onTcpMsg = msg; else this.onTlsMsg = msg; }
  clearListeners(): void { if (!this.tlsUpgraded) this.onTcpMsg = null; else this.onTlsMsg = null; }
  async connect(_h: string, _p: number, _t: number): Promise<void> {}
  prepareUpgrade(): void { this.onTcpMsg = null; } upgrade(): PostgresTlsSocket { this.tlsUpgraded = true; return this; }
  async connectTls(_h: string, _p: number, _c: PostgresSslConfig, _t: number): Promise<void> {}
  async verifyPeerIdentity(_h: string): Promise<void> { this.peerVerified = true; }
  async send(data: Uint8Array): Promise<void> {
    const copy = new Uint8Array(data.length); copy.set(data);
    if (!this.tlsUpgraded) { this.rawTcpWriteRefs.push(data); this.tcpWrites.push(copy); if (this.tcpReplies.length > 0 && this.onTcpMsg !== null) this.onTcpMsg(this.tcpReplies.shift()!); }
    else { this.rawTlsWriteRefs.push(data); this.tlsWrites.push(copy); if (this.failTlsSendAt > 0 && this.tlsWrites.length === this.failTlsSendAt) throw new Error('tls send failed'); if (this.tlsReplies.length > 0 && this.onTlsMsg !== null) this.onTlsMsg(this.tlsReplies.shift()!); }
  }
  async close(): Promise<void> {}
}
class NullReadTransport implements PostgresLifecycleTransport {
  async connect(_h: string, _p: number, _t: number): Promise<void> {} async read(_m: number): Promise<Uint8Array | null> { return null; }
  async write(d: Uint8Array): Promise<number> { return d.length; } async close(): Promise<void> {} async abort(_e: ArkDbError): Promise<void> {}
}
class SubarrayChunkTransport extends NullReadTransport {
  private readonly chunks: Uint8Array[]; constructor(chunks: Uint8Array[]) { super(); this.chunks = chunks; }
  async read(_m: number): Promise<Uint8Array | null> { return this.chunks.length > 0 ? this.chunks.shift()! : null; }
}
class PassiveTimers implements ConnectionTimerPort {
  currentMs: number = 1000; private id: number = 1;
  nowMs(): number { return this.currentMs; } schedule(_h: () => void, _ms: number): number { return this.id++; } cancel(_id: number): void {}
}
class StubAuthPlatform implements PostgresAuthPlatform {
  private md5Call: number = 0;
  async randomBytes(len: number): Promise<Uint8Array> { return new Uint8Array(len); }
  async md5(_d: Uint8Array): Promise<Uint8Array> { this.md5Call += 1; return hexBytes(this.md5Call === 1 ? '4d45974e13472b5a0be3533de4666414' : 'd6f407104ca5ba8553d598fed7df90e0'); }
  async sha256(_d: Uint8Array): Promise<Uint8Array> { return new Uint8Array(32); }
  async hmacSha256(_k: Uint8Array, _d: Uint8Array): Promise<Uint8Array> { return new Uint8Array(32); } normalizeNfkc(val: string): string { return val; }
}
class RfcScramPort implements PostgresScramPort {
  async createNonce(): Promise<string> { return RFC_NONCE; } preparePassword(val: string): Uint8Array { return strictUtf8Encode(val); }
  async deriveSaltedPassword(_pw: Uint8Array, _salt: Uint8Array, _iter: number): Promise<Uint8Array> { return hexBytes('c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d'); }
  async sha256(_d: Uint8Array): Promise<Uint8Array> { return hexBytes('586e5df283e6dceb5c3e791d8b8528ec191e664045ce971792e2e6b5bb13e2a6'); }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const k = bytesHex(key);
    if (k === 'c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d') return hexBytes(strictUtf8Decode(data) === 'Client Key' ? 'a60fc923d67e8644a92d16b96eda5ef4656b0c725c484374be25535576996e8b' : 'c1f3cbc1c13a9d35a14c0990eed97629ea225863e566a4314ab99f3f00e5d9d5');
    return hexBytes(k === '586e5df283e6dceb5c3e791d8b8528ec191e664045ce971792e2e6b5bb13e2a6' ? 'd27312467c28a40a8a7f05c73c0de33eb3cbfb4a83783b58144cf19ac6be1bdf' : 'eabae24d1062db75a9451ff0b6ea7e98c8546549ff741e672d3251b2397de46e');
  }
}
function expectedStartupFrame(user: string, db: string, app: string): Uint8Array {
  const parts: number[] = [0x00, 0x03, 0x00, 0x00]; pushCStr(parts, 'user'); pushCStr(parts, user); pushCStr(parts, 'database'); pushCStr(parts, db);
  if (app.length > 0) { pushCStr(parts, 'application_name'); pushCStr(parts, app); }
  pushCStr(parts, 'client_encoding'); pushCStr(parts, 'UTF8'); parts.push(0x00);
  const out = new Uint8Array(parts.length + 4); new DataView(out.buffer).setInt32(0, out.length, false); out.set(parts, 4); return out;
}
function backendFrame(type: number, payload: number[]): Uint8Array { const out = new Uint8Array(payload.length + 5); out[0] = type; new DataView(out.buffer).setInt32(1, payload.length + 4, false); out.set(payload, 5); return out; }
function msgAuthOk(): Uint8Array { return msgAuthCode(0); } function msgAuthCleartext(): Uint8Array { return msgAuthCode(3); }
function msgAuthMd5(salt: number[]): Uint8Array { return backendFrame(0x52, [0, 0, 0, 5, salt[0], salt[1], salt[2], salt[3]]); }
function msgAuthCode(code: number): Uint8Array { return backendFrame(0x52, [0, 0, 0, code]); }
function msgAuthSasl(mechanisms: string[]): Uint8Array { const p: number[] = [0, 0, 0, 10]; for (const m of mechanisms) pushCStr(p, m); p.push(0); return backendFrame(0x52, p); }
function msgAuthSaslContinue(text: string): Uint8Array { const p: number[] = [0, 0, 0, 11]; pushAscii(p, text); return backendFrame(0x52, p); }
function msgAuthSaslFinal(text: string): Uint8Array { const p: number[] = [0, 0, 0, 12]; pushAscii(p, text); return backendFrame(0x52, p); }
function expectedSaslInitialFrame(mech: string, initial: string): Uint8Array {
  const p: number[] = []; pushCStr(p, mech); const lenBytes = new Uint8Array(4); new DataView(lenBytes.buffer).setInt32(0, initial.length, false);
  for (let i = 0; i < 4; i += 1) p.push(lenBytes[i]); pushAscii(p, initial); return backendFrame(0x70, p);
}
function expectedSaslResponseFrame(resp: string): Uint8Array { const p: number[] = []; pushAscii(p, resp); return backendFrame(0x70, p); }
function msgParam(name: string, val: string): Uint8Array { const p: number[] = []; pushCStr(p, name); pushCStr(p, val); return backendFrame(0x53, p); }
function msgBackendKey(pid: number, key: number[]): Uint8Array { const p = new Uint8Array(8); new DataView(p.buffer).setInt32(0, pid, false); p.set(key, 4); return backendFrame(0x4b, Array.from(p)); }
function msgNotice(loc: string, state: string, msg: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x43); pushCStr(p, state); p.push(0x4d); pushCStr(p, msg); p.push(0); return backendFrame(0x4e, p); }
function msgError(loc: string, sev: string, state: string, msg: string): Uint8Array { const p: number[] = [0x53]; pushCStr(p, loc); p.push(0x56); pushCStr(p, sev); p.push(0x43); pushCStr(p, state); p.push(0x4d); pushCStr(p, msg); p.push(0); return backendFrame(0x45, p); }
function msgNotification(pid: number, ch: string, payload: string): Uint8Array { const head = new Uint8Array(4); new DataView(head.buffer).setInt32(0, pid, false); const p = Array.from(head); pushCStr(p, ch); pushCStr(p, payload); return backendFrame(0x41, p); }
function msgNegotiate(minor: number, opts: string[]): Uint8Array { const head = new Uint8Array(8); const v = new DataView(head.buffer); v.setInt32(0, minor, false); v.setInt32(4, opts.length, false); const p = Array.from(head); for (const o of opts) pushCStr(p, o); return backendFrame(0x76, p); }
function msgReady(status: number): Uint8Array { return backendFrame(0x5a, [status]); }
function pushAscii(dst: number[], text: string): void { for (let i = 0; i < text.length; i += 1) dst.push(text.charCodeAt(i)); }
function pushCStr(dst: number[], text: string): void { pushAscii(dst, text); dst.push(0); }
function bytesHex(val: Uint8Array): string { let out = ''; for (let i = 0; i < val.length; i += 1) out += val[i].toString(16).padStart(2, '0'); return out; }
function hexBytes(hex: string): Uint8Array { const out = new Uint8Array(hex.length / 2); for (let i = 0; i < out.length; i += 1) out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16); return out; }
function concatFrames(frames: Uint8Array[]): Uint8Array { let len = 0; for (const f of frames) len += f.length; const out = new Uint8Array(len); let off = 0; for (const f of frames) { out.set(f, off); off += f.length; } return out; }
async function expectOk(op: () => Promise<void>): Promise<void> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err === null).assertTrue(); }
async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> { let err: Object | null = null; try { await op(); } catch (e) { err = e as Object; } expect(err instanceof ArkDbError).assertTrue(); return err as ArkDbError; }
class LatchGate {
  private openFn: () => void = (): void => {}; private enterFn: () => void = (): void => {};
  readonly entered: Promise<void> = new Promise<void>((r: () => void): void => { this.enterFn = r; });
  private readonly gate: Promise<void> = new Promise<void>((r: () => void): void => { this.openFn = r; });
  pause(): Promise<void> { this.enterFn(); return this.gate; } release(): void { this.openFn(); }
}
class PausedMd5Platform extends StubAuthPlatform {
  readonly latch: LatchGate = new LatchGate(); get entered(): Promise<void> { return this.latch.entered; } release(): void { this.latch.release(); }
  async md5(data: Uint8Array): Promise<Uint8Array> { await this.latch.pause(); return super.md5(data); }
}
class PausedDefaultPbkdf2Platform extends StubAuthPlatform {
  hmacCalls: number = 0; firstShaRef: Uint8Array | null = null; firstKeyRef: Uint8Array | null = null; private readonly latch: LatchGate = new LatchGate();
  get entered(): Promise<void> { return this.latch.entered; } release(): void { this.latch.release(); }
  async randomBytes(len: number): Promise<Uint8Array> { const b = new Uint8Array(len); for (let i = 0; i < len; i += 1) b[i] = i; return b; }
  async sha256(data: Uint8Array): Promise<Uint8Array> { this.firstShaRef = data; const out = new Uint8Array(32); out[0] = 0x5a; return out; }
  async hmacSha256(key: Uint8Array, _data: Uint8Array): Promise<Uint8Array> {
    this.hmacCalls += 1; if (this.hmacCalls === 1) { this.firstKeyRef = key; await this.latch.pause(); } return new Uint8Array(32);
  }
}
class PausedScramPort extends RfcScramPort {
  hmacAfterDispose: number = 0; private closed: boolean = false; private hmacCount: number = 0; private readonly latch: LatchGate = new LatchGate();
  get deriveEntered(): Promise<void> { return this.latch.entered; } releaseDerive(): void { this.closed = true; this.latch.release(); }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    this.hmacCount += 1; if (this.closed) this.hmacAfterDispose += 1; if (this.hmacCount === 1) await this.latch.pause();
    return super.hmacSha256(key, data);
  }
}
class PostExpiryScramPort extends RfcScramPort {
  private readonly timers: PassiveTimers; private calls: number = 0; constructor(timers: PassiveTimers) { super(); this.timers = timers; }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> { this.calls += 1; if (this.calls === 4) this.timers.currentMs += 1000; return super.hmacSha256(key, data); }
}
async function flushTicks(count: number): Promise<void> { for (let i = 0; i < count; i += 1) await Promise.resolve(); }
function assertZeroed(actual: Uint8Array): void { expect(actual.length > 0).assertTrue(); for (let i = 0; i < actual.length; i += 1) expect(actual[i]).assertEqual(0); }
function assertBytes(actual: Uint8Array, expected: ArrayLike<number>): void { expect(actual.length).assertEqual(expected.length); for (let i = 0; i < expected.length; i += 1) expect(actual[i]).assertEqual(expected[i]); }
