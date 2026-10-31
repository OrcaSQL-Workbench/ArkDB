import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';

export default function mySqlCommandGateTest(): void {
  describe('MySQL internal command ownership', () => {
    it('rejectsExternalReentryButAllowsOwnedSubcommand', 0, () => {
      const gate = new MySqlCommandGate();
      const scope = gate.reserve(MySqlCommandKind.Transaction);
      expect(scope.phase).assertEqual(MySqlCommandPhase.Reserved);
      expectProtocol((): void => { gate.reserve(MySqlCommandKind.Query); });

      gate.assertOwner(scope);
      gate.setPhase(scope, MySqlCommandPhase.Executing);
      expect(scope.phase).assertEqual(MySqlCommandPhase.Executing);
      const foreignGate = new MySqlCommandGate();
      const foreign = foreignGate.reserve(MySqlCommandKind.Transaction);
      expect(foreign.serial).assertEqual(scope.serial);
      expect(foreign.generation).assertEqual(scope.generation);
      expect(foreign.ownerToken === scope.ownerToken).assertFalse();
      expectProtocol((): void => { gate.assertOwner(foreign); });
      expectProtocol((): void => { gate.setPhase(foreign, MySqlCommandPhase.Cleaning); });
      expectProtocol((): void => { gate.release(foreign); });
      expect(gate.current === scope).assertTrue();

      gate.setPhase(scope, MySqlCommandPhase.Cleaning);
      gate.release(scope);
      expect(scope.phase).assertEqual(MySqlCommandPhase.Settled);
      expect(gate.current === null).assertTrue();
      expectProtocol((): void => { gate.release(scope); });
      const next = gate.reserve(MySqlCommandKind.Ping);
      expect(next.serial).assertEqual(2);
      expect(next.generation).assertEqual(scope.generation);
      expect(next.ownerToken === scope.ownerToken).assertFalse();
      expectProtocol((): void => { gate.assertOwner(scope); });
      gate.release(next);
    });

    it('neverAdvancesTheSessionGenerationWhileAnOwnerIsUnsettled', 0, () => {
      const gate = new MySqlCommandGate();
      gate.advanceGeneration();
      const first = gate.reserve(MySqlCommandKind.Connect);
      expect(first.generation).assertEqual(1);
      expectProtocol((): void => { gate.advanceGeneration(); });
      gate.assertOwner(first);
      gate.release(first);
      gate.advanceGeneration();
      const next = gate.reserve(MySqlCommandKind.Connect);
      expect(next.generation).assertEqual(2);
      expect(next.serial).assertEqual(2);
      expectProtocol((): void => { gate.assertOwner(first); });
      gate.release(next);
    });

    it('blocksResetWhileAnExternalCursorOwnsTheGeneration', 0, () => {
      const gate = new MySqlCommandGate();
      gate.advanceGeneration();
      const cursor = gate.reserve(MySqlCommandKind.QueryStream);
      gate.setPhase(cursor, MySqlCommandPhase.CursorIdle);
      expectProtocol((): void => { gate.reserve(MySqlCommandKind.Reset); });
      gate.advanceGenerationOnRelease(cursor);
      gate.advanceGenerationOnRelease(cursor);
      expect(gate.generation).assertEqual(cursor.generation);
      gate.release(cursor);
      expect(gate.generation).assertEqual(cursor.generation + 1);
      const reset = gate.reserve(MySqlCommandKind.Reset);
      expect(reset.generation).assertEqual(cursor.generation + 1);
      gate.release(reset);
    });

    it('retainsCanonicalErrorIdentityAndIndependentPrimaryFields', 0, () => {
      const primary = ArkDbError.server('Synthetic server rejection.', 'ER_SYNTHETIC', '45000');
      const cleanup = ArkDbError.network('Synthetic cleanup failure.');
      const original = new Error('Synthetic callback failure.');
      const cleanupErrors = [cleanup];
      const failure = new MySqlOperationError(primary, cleanupErrors,
        MySqlExecutionOutcome.Unknown, original);
      cleanupErrors.push(ArkDbError.timeout('Later unrelated error.'));

      expect(failure instanceof ArkDbError).assertTrue();
      expect(failure.primary === primary).assertTrue();
      expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
      expect(failure.nativeCode).assertEqual('ER_SYNTHETIC');
      expect(failure.code === undefined).assertTrue();
      expect(failure.sqlState).assertEqual('45000');
      expect(failure.cleanupErrors.length).assertEqual(1);
      expect(failure.cleanupErrors[0] === cleanup).assertTrue();
      expect(failure.originalCause === original).assertTrue();
      expect(failure.outcome).assertEqual('unknown');

      const numeric = new MySqlOperationError(ArkDbError.server('Numeric rejection.', 1064, '42000'),
        [], MySqlExecutionOutcome.ServerRejected);
      expect(numeric.code).assertEqual(1064);
      expect(numeric.nativeCode).assertEqual(1064);
      expect(numeric.sqlState).assertEqual('42000');
      expect(numeric.originalCause === undefined).assertTrue();
      expect(MySqlExecutionOutcome.NotDispatched).assertEqual('not_dispatched');
      expect(MySqlExecutionOutcome.ServerRejected).assertEqual('server_rejected');
      expect(MySqlExecutionOutcome.Completed).assertEqual('completed');
    });
  });
}

function expectProtocol(action: () => void): void {
  let failure: ArkDbError | null = null;
  try { action(); } catch (error) {
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}
