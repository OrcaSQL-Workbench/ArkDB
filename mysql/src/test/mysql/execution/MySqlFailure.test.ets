import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  mergeCleanupEvidence, mysqlCleanupError, mysqlOperationContains,
  mysqlOperationFailure
} from '../../../main/ets/mysql/execution/MySqlFailure';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlUploadFailure } from '../../../main/ets/mysql/transport/MySqlUploadPump';
import {
  preparedCleanup, preparedFailure
} from '../../../main/ets/mysql/command/PreparedStatement';

export default function mySqlFailureTest(): void {
  describe('MySQL failure composition', () => {
    it('preservesPrimaryFieldsAndCleanupOrder', 0, () => {
      const primary = ArkDbError.server(
        'Synthetic server rejection.', 'ER_SYNTHETIC', '45000');
      const firstCleanup = ArkDbError.network('Synthetic first cleanup failure.');
      const secondCleanup = ArkDbError.timeout('Synthetic second cleanup failure.');
      const cleanup = [firstCleanup, secondCleanup];

      const failure = mysqlOperationFailure(
        primary, cleanup, MySqlExecutionOutcome.ServerRejected);
      cleanup.push(ArkDbError.protocol('Later unrelated cleanup failure.'));

      expect(failure.primary === primary).assertTrue();
      expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
      expect(failure.message).assertEqual(
        'Synthetic server rejection. Connection cleanup failed.');
      expect(failure.nativeCode).assertEqual('ER_SYNTHETIC');
      expect(failure.code === undefined).assertTrue();
      expect(failure.sqlState).assertEqual('45000');
      expect(failure.cleanupErrors.length).assertEqual(2);
      expect(failure.cleanupErrors[0] === firstCleanup).assertTrue();
      expect(failure.cleanupErrors[1] === secondCleanup).assertTrue();
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
      expect(failure.originalCause === undefined).assertTrue();
    });

    it('appendsNestedCleanupWithoutRemovingDuplicateEvidence', 0, () => {
      const primary = ArkDbError.network('Synthetic nested primary.');
      const firstCleanup = ArkDbError.protocol('Synthetic nested cleanup.');
      const duplicate = ArkDbError.timeout('Synthetic duplicate cleanup.');
      const secondCleanup = ArkDbError.cancelled('Synthetic appended cleanup.');
      const original = new Error('Synthetic original operation cause.');
      const nested = new MySqlOperationError(
        primary, [firstCleanup, duplicate], MySqlExecutionOutcome.Completed, original);

      const failure = mysqlOperationFailure(
        nested, [secondCleanup, duplicate], MySqlExecutionOutcome.Unknown);

      expect(failure.primary === primary).assertTrue();
      expect(failure.cleanupErrors.length).assertEqual(4);
      expect(failure.cleanupErrors[0] === firstCleanup).assertTrue();
      expect(failure.cleanupErrors[1] === duplicate).assertTrue();
      expect(failure.cleanupErrors[2] === secondCleanup).assertTrue();
      expect(failure.cleanupErrors[3] === duplicate).assertTrue();
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(failure.originalCause === original).assertTrue();
    });

    it('keepsArkDbCleanupIdentityAndCapturesOrdinaryCauses', 0, () => {
      const typed = ArkDbError.timeout('Synthetic typed cleanup.');
      const ordinary = new Error('Synthetic ordinary cleanup.');

      expect(mysqlCleanupError(typed) === typed).assertTrue();
      const failure = mysqlCleanupError(ordinary);

      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.originalCause === ordinary).assertTrue();
      }
    });

    it('preservesPreparedOrdinaryFailureMessageAndCause', 0, () => {
      const ordinary = new Error('Synthetic prepared implementation failure.');
      const cleanup = ArkDbError.network('Synthetic prepared cleanup failure.');

      const failure = preparedFailure(
        ordinary, [cleanup], MySqlExecutionOutcome.Unknown);

      expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(failure.primary.message).assertEqual(
        'Unexpected prepared statement operation failure.');
      expect(failure.originalCause === ordinary).assertTrue();
      expect(failure.cleanupErrors.length).assertEqual(1);
      expect(failure.cleanupErrors[0] === cleanup).assertTrue();
      const cleanupCause = new Error('Synthetic prepared cleanup cause.');
      const cleanupFailure = preparedCleanup(cleanupCause);
      expect(cleanupFailure instanceof MySqlOperationError).assertTrue();
      if (cleanupFailure instanceof MySqlOperationError) {
        expect(cleanupFailure.primary.message).assertEqual(
          'Unexpected prepared statement operation failure.');
        expect(cleanupFailure.originalCause === cleanupCause).assertTrue();
      }
    });

    it('mergesCleanupEvidenceByExactIdentityOnly', 0, () => {
      const first = ArkDbError.network('Synthetic first evidence.');
      const second = ArkDbError.protocol('Synthetic second evidence.');
      const sharedCause = new Error('Synthetic shared upload cause.');
      const firstWrapper = new MySqlUploadFailure(
        ArkDbError.protocol('Synthetic first upload wrapper.'),
        [], false, sharedCause);
      const secondWrapper = new MySqlUploadFailure(
        ArkDbError.protocol('Synthetic second upload wrapper.'),
        [], false, sharedCause);
      const existing = [first, first, firstWrapper];
      const additions = [first, secondWrapper, second, firstWrapper];

      const merged = mergeCleanupEvidence(existing, additions);
      existing.push(ArkDbError.timeout('Later existing evidence.'));
      additions.push(ArkDbError.cancelled('Later added evidence.'));

      expect(merged.length).assertEqual(4);
      expect(merged[0] === first).assertTrue();
      expect(merged[1] === firstWrapper).assertTrue();
      expect(merged[2] === secondWrapper).assertTrue();
      expect(merged[3] === second).assertTrue();
    });

    it('containsOnlyNestedOperationErrorReferences', 0, () => {
      const primary = ArkDbError.server(
        'Synthetic nested rejection.', 1205, 'HY000');
      const nestedCleanup = ArkDbError.network('Synthetic nested cleanup.');
      const outerCleanup = ArkDbError.timeout('Synthetic outer cleanup.');
      const unrelatedOriginalCause =
        ArkDbError.protocol('Synthetic unrelated original cause.');
      const sameValue = ArkDbError.network('Synthetic nested cleanup.');
      const nested = new MySqlOperationError(
        primary, [nestedCleanup], MySqlExecutionOutcome.ServerRejected,
        unrelatedOriginalCause);
      const outer = new MySqlOperationError(
        nested, [outerCleanup], MySqlExecutionOutcome.Unknown);

      expect(mysqlOperationContains(outer, outer)).assertTrue();
      expect(mysqlOperationContains(outer, nested)).assertTrue();
      expect(mysqlOperationContains(outer, primary)).assertTrue();
      expect(mysqlOperationContains(outer, nestedCleanup)).assertTrue();
      expect(mysqlOperationContains(outer, outerCleanup)).assertTrue();
      expect(mysqlOperationContains(outer, unrelatedOriginalCause)).assertFalse();
      expect(mysqlOperationContains(outer, sameValue)).assertFalse();
    });
  });
}
