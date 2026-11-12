import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresCommandGate, PostgresCommandKind, PostgresCommandLifecycleObserver,
  PostgresCommandPhase, PostgresCommandScope
} from '../../../main/ets/pgsql/execution/PostgresCommandGate';
import {
  PostgresCommandCloseSettlement, applyPostgresReadyStatus,
  postgresAppendCleanupError, resetPostgresSessionStatus, toPostgresArkDbError
} from '../../../main/ets/pgsql/execution/PostgresSettlements';
import {
  PostgresDatabaseSessionStatus, PostgresError, PostgresTransactionState
} from '../../../main/ets/pgsql/model/PostgresModels';
import { PostgresReadyStatus } from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

export default function postgresCommandGateTest(): void {
  describe('PostgresCommandGate', () => {
    it('enforcesSingleFlightCommandGatePhasesDeadlinesAndGenerations', 0, () => {
      const events: string[] = [];
      let gateRef: PostgresCommandGate | null = null;
      const gate = new PostgresCommandGate(new RecordingGateObserver(events, (): string =>
        String(gateRef!.current === null) + ':' + String(gateRef!.generation)));
      gateRef = gate;
      expect(gate.current === null && gate.generation === 0 && !gate.hasReserved).assertTrue();
      const first = gate.reserve(PostgresCommandKind.Query);
      expect(gate.hasReserved && gate.isOwner(first)).assertTrue();
      expect(first.serial === 1 && first.generation === 0).assertTrue();
      expect(first.phase).assertEqual(PostgresCommandPhase.Reserved);
      const forged = new ForgedCommandScope(first.serial, first.generation, first.kind);
      expect(gate.isOwner(forged)).assertFalse();
      expect(syncFail((): void => gate.assertOwner(forged)).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(syncFail((): void => gate.release(first)).kind).assertEqual(ArkDbErrorKind.Protocol);
      const overlap = syncFail((): void => { gate.reserve(PostgresCommandKind.Ping); });
      expect(overlap.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(overlap.message).assertEqual('Another command already owns this PostgreSQL connection.');
      expect(syncFail((): void => gate.advanceGeneration()).kind).assertEqual(ArkDbErrorKind.Protocol);
      gate.start(first);
      expect(syncFail((): void => gate.start(first)).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(syncFail((): void => gate.setPhase(first, PostgresCommandPhase.Settled)).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      for (const phase of [PostgresCommandPhase.Connecting, PostgresCommandPhase.Authenticating,
        PostgresCommandPhase.Executing, PostgresCommandPhase.Streaming,
        PostgresCommandPhase.Draining, PostgresCommandPhase.Closing]) {
        gate.setPhase(first, phase);
        expect(first.phase).assertEqual(phase);
      }
      gate.assertDeadlineActive(first);
      expect(gate.expireDeadline(first, 999) || gate.expireDeadline(forged, first.serial)).assertFalse();
      expect(first.deadlineExpired).assertFalse();
      expect(gate.expireDeadline(first, first.serial) && first.deadlineExpired).assertTrue();
      expect(syncFail((): void => gate.assertDeadlineActive(first)).kind).assertEqual(ArkDbErrorKind.Timeout);
      gate.advanceGenerationOnRelease(first);
      gate.release(first);
      expect(first.phase).assertEqual(PostgresCommandPhase.Settled);
      expect(gate.current === null && gate.generation === 1 && !gate.isOwner(first)).assertTrue();
      expect(events.join(',')).assertEqual('start:1:query,terminal:1:settled:true:1');
      expect(syncFail((): void => gate.assertOwner(first)).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(syncFail((): void => gate.setPhase(first, PostgresCommandPhase.Draining)).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(syncFail((): void => gate.advanceGenerationOnRelease(first)).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(syncFail((): void => gate.release(first)).kind).assertEqual(ArkDbErrorKind.Protocol);
      gate.advanceGeneration();
      expect(gate.generation).assertEqual(2);
      const plainGate = new PostgresCommandGate();
      const plainScope = plainGate.reserve(PostgresCommandKind.Close);
      plainGate.release(plainScope);
      expect(plainGate.generation === 0 && plainGate.current === null).assertTrue();
    });

    it('coordinatesCloseSettlementSignalWaitersAndCompletion', 0, async () => {
      const gate = new PostgresCommandGate();
      const scope = gate.reserve(PostgresCommandKind.QueryStream);
      gate.start(scope);
      const settlement = new PostgresCommandCloseSettlement(scope);
      expect(!settlement.isCloseRequested && settlement.closeReason === null &&
        !settlement.isSettled && settlement.scope === scope).assertTrue();
      expect(await settlement.raceClose<number>(async (): Promise<number> => 7)).assertEqual(7);
      expect(await settlement.raceClose<string>(async (): Promise<string> => 'done')).assertEqual('done');
      expect((await asyncRawFail((): Promise<void> =>
        settlement.raceClose<void>((): Promise<void> => { throw new Error('sync boom'); }))).message)
        .assertEqual('sync boom');
      const pending = settlement.raceClose<void>((): Promise<void> =>
        new Promise<void>((_resolve: () => void): void => {}));
      const firstCancel = ArkDbError.cancelled('PostgreSQL connection closed during operation.');
      settlement.signalClose(firstCancel);
      settlement.signalClose(ArkDbError.cancelled('ignored second close reason'));
      expect(settlement.isCloseRequested && settlement.closeReason === firstCancel).assertTrue();
      expect(await asyncFail((): Promise<void> => pending)).assertEqual(firstCancel);
      expect(await settlement.closeRequested).assertEqual(firstCancel);
      expect(await asyncFail((): Promise<void> =>
        settlement.raceClose<void>(async (): Promise<void> => {}))).assertEqual(firstCancel);
      const reentrant = new PostgresCommandCloseSettlement(gate.current!);
      const reentrantCancel = ArkDbError.cancelled('reentrant close');
      expect(await asyncFail((): Promise<void> =>
        reentrant.raceClose<void>((): Promise<void> => {
          reentrant.signalClose(reentrantCancel);
          return new Promise<void>((_resolve: () => void): void => {});
        }))).assertEqual(reentrantCancel);
      let settledResolved = false;
      const settledWatch = settlement.settled.then((): void => { settledResolved = true; });
      settlement.markSettled();
      settlement.markSettled();
      await settledWatch;
      expect(settledResolved && settlement.isSettled).assertTrue();

      const unclosed = new PostgresCommandCloseSettlement(scope);
      const orphaned = unclosed.raceClose<void>((): Promise<void> =>
        new Promise<void>((_resolve: () => void): void => {}));
      unclosed.markSettled();
      expect((await asyncFail((): Promise<void> => orphaned)).kind).assertEqual(ArkDbErrorKind.Protocol);
      unclosed.signalClose(ArkDbError.cancelled('late close after settle'));
      expect(!unclosed.isCloseRequested && unclosed.closeReason === null).assertTrue();
      let postSettleInvoked = false;
      expect((await asyncFail((): Promise<void> => unclosed.raceClose<void>((): Promise<void> => {
        postSettleInvoked = true;
        return Promise.resolve();
      }))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(postSettleInvoked).assertFalse();
      gate.release(scope);
    });

    it('synchronizesReadyForQueryTransactionStatesAndResetsOnFailure', 0, () => {
      const status = new PostgresDatabaseSessionStatus();
      expect(status.known).assertFalse();
      applyPostgresReadyStatus(status, PostgresReadyStatus.Idle);
      expect(status.known && status.autocommit && !status.inTransaction).assertTrue();
      expect(status.transactionState).assertEqual(PostgresTransactionState.Idle);
      applyPostgresReadyStatus(status, PostgresReadyStatus.InTransaction);
      expect(status.known && status.autocommit && status.inTransaction).assertTrue();
      expect(status.transactionState).assertEqual(PostgresTransactionState.InTransaction);
      applyPostgresReadyStatus(status, PostgresReadyStatus.FailedTransaction);
      expect(status.known && status.autocommit && status.inTransaction).assertTrue();
      expect(status.transactionState).assertEqual(PostgresTransactionState.FailedTransaction);
      expect(syncFail((): void => applyPostgresReadyStatus(status, 0x3f as PostgresReadyStatus)).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(!status.known && !status.autocommit && !status.inTransaction &&
        status.transactionState === PostgresTransactionState.Idle).assertTrue();
      applyPostgresReadyStatus(status, PostgresReadyStatus.InTransaction);
      resetPostgresSessionStatus(status);
      expect(!status.known && !status.autocommit && !status.inTransaction &&
        status.transactionState === PostgresTransactionState.Idle).assertTrue();
    });

    it('preservesPostgresErrorFieldsAndNormalizesCleanupFailures', 0, () => {
      const primary = new PostgresError(ArkDbErrorKind.Auth, 'password auth failed', '28P01', '28P01');
      primary.severity = 'FATAL'; primary.localizedSeverity = 'FATAL';
      primary.detail = 'Role blocked'; primary.hint = 'Check pg_hba.conf';
      primary.position = 12; primary.internalPosition = 4;
      primary.internalQuery = 'SELECT 1'; primary.where = 'auth_check';
      primary.schemaName = 'pg_catalog'; primary.tableName = 'pg_authid';
      primary.columnName = 'rolpassword'; primary.dataTypeName = 'text';
      primary.constraintName = 'auth_policy'; primary.sourceFile = 'auth.c';
      primary.sourceLine = 512; primary.sourceRoutine = 'auth_failed';
      expect(postgresAppendCleanupError(primary, primary) === primary).assertTrue();
      const cleanup = ArkDbError.network('socket close failed');
      const composed = postgresAppendCleanupError(primary, cleanup) as PostgresError;
      expect(composed instanceof PostgresError && primary.message === 'password auth failed').assertTrue();
      expect(composed.kind === ArkDbErrorKind.Auth && composed.sqlState === '28P01' &&
        composed.nativeCode === '28P01' && composed.code === undefined).assertTrue();
      expect(composed.severity === 'FATAL' && composed.localizedSeverity === 'FATAL' &&
        composed.detail === 'Role blocked' && composed.hint === 'Check pg_hba.conf').assertTrue();
      expect(composed.position === 12 && composed.internalPosition === 4 &&
        composed.internalQuery === 'SELECT 1' && composed.where === 'auth_check').assertTrue();
      expect(composed.schemaName === 'pg_catalog' && composed.tableName === 'pg_authid' &&
        composed.columnName === 'rolpassword' && composed.dataTypeName === 'text').assertTrue();
      expect(composed.constraintName === 'auth_policy' && composed.sourceFile === 'auth.c' &&
        composed.sourceLine === 512 && composed.sourceRoutine === 'auth_failed').assertTrue();
      expect(composed.message.indexOf('password auth failed') >= 0 &&
        composed.message.indexOf('socket close failed') >= 0).assertTrue();
      const numeric = postgresAppendCleanupError(new ArkDbError(ArkDbErrorKind.Tls, 'tls', 48), cleanup);
      expect(numeric.kind === ArkDbErrorKind.Tls && numeric.code === 48 && numeric.nativeCode === 48).assertTrue();
      expect(toPostgresArkDbError(primary, ArkDbErrorKind.Network) === primary).assertTrue();
      const fromError = toPostgresArkDbError(new Error('raw disconnect'), ArkDbErrorKind.Network);
      expect(fromError.kind === ArkDbErrorKind.Network && fromError.message === 'raw disconnect').assertTrue();
      const fromText = toPostgresArkDbError('plain failure');
      expect(fromText.kind === ArkDbErrorKind.Protocol && fromText.message === 'plain failure').assertTrue();
    });
  });
}

class RecordingGateObserver implements PostgresCommandLifecycleObserver {
  private readonly events: string[];
  private readonly snapshot: () => string;
  constructor(events: string[], snapshot: () => string) { this.events = events; this.snapshot = snapshot; }
  onStart(scope: PostgresCommandScope): void { this.events.push('start:' + scope.serial + ':' + scope.kind); }
  onTerminal(scope: PostgresCommandScope): void {
    this.events.push('terminal:' + scope.serial + ':' + scope.phase + ':' + this.snapshot());
  }
}

class ForgedCommandScope implements PostgresCommandScope {
  readonly serial: number;
  readonly generation: number;
  readonly kind: PostgresCommandKind;
  readonly phase: PostgresCommandPhase = PostgresCommandPhase.Reserved;
  readonly deadlineExpired: boolean = false;
  readonly ownerToken: Object = new Object();
  constructor(serial: number, generation: number, kind: PostgresCommandKind) {
    this.serial = serial; this.generation = generation; this.kind = kind;
  }
}

function syncFail(op: () => void): ArkDbError {
  try { op(); } catch (e) { if (e instanceof ArkDbError) return e; throw e as Error; }
  throw new Error('Expected synchronous ArkDbError');
}

async function asyncFail<T>(op: () => Promise<T>): Promise<ArkDbError> {
  try { await op(); } catch (e) { if (e instanceof ArkDbError) return e; throw e as Error; }
  throw new Error('Expected asynchronous ArkDbError');
}

async function asyncRawFail<T>(op: () => Promise<T>): Promise<Error> {
  try { await op(); } catch (e) { return e as Error; }
  throw new Error('Expected asynchronous Error');
}
