import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions
} from '@arkdb/core';
import { MySqlProcedureCaller } from '../../../main/ets/mysql/execution/MySqlProcedureCaller';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlProcedureArgument, MySqlParameterDirection
} from '../../../main/ets/mysql/model/MySqlProcedure';
import { MySqlParameter, MySqlParameterType } from '../../../main/ets/mysql/model/MySqlParameter';
import { MySqlValue } from '../../../main/ets/mysql/model/MySqlQueryResult';
import {
  Capabilities, ColumnType, FieldFlag, StatusFlags
} from '../../../main/ets/mysql/protocol/Constants';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import {
  PreparedExecutionFixture, columnPayload, hex, okPayload, preparedFailureOf, prepareResponse
} from '../command/PreparedExecutionFixture';

export default function mySqlProcedureCallerTest(): void {
  describe('MySQL binary procedure caller', () => {
    it('classicOutMetadataContinuesThroughFinalOkAndNextPing', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
      fixture.peer.responses.push(
        prepareResponse(6, 1),
        binaryIntResult(['ordinary'], [11], 0, more, false)
          .concat(binaryIntResult(['p_out'], [200],
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT, false))
          .concat([okPayload()]),
        [okPayload()]
      );

      try {
        const result = await caller.call(['classic_out'], [
          procedureParameter(MySqlParameterDirection.Out, 0)
        ]);

        expect(result.results.length).assertEqual(3);
        expect(result.outResultIndex).assertEqual(1);
        expect(result.outValues[0]).assertEqual(200);
        expect(result.results[2].rows.length).assertEqual(0);
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('outResultIsRecognizedByStatusNotPosition', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const deprecatedEof = mode === 1;
        const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41 |
          Capabilities.PS_MULTI_RESULTS |
          (deprecatedEof ? Capabilities.DEPRECATE_EOF : 0));
        await fixture.open();
        const caller: MySqlProcedureCaller = procedureFeature(fixture);
        const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
        fixture.peer.responses.push(
          prepareResponse(7, 3, [], deprecatedEof),
          binaryIntResult(['ordinary_before'], [11], 0, more, deprecatedEof)
            .concat(binaryIntResult(['ordinary_after'], [22], 0, more, deprecatedEof))
            .concat(binaryIntResult(['p_out', 'p_inout'], [200, 300],
              StatusFlags.PS_OUT_PARAMS |
                (deprecatedEof ? 0 : StatusFlags.MORE_RESULTS_EXISTS),
              deprecatedEof ? more : StatusFlags.AUTOCOMMIT, deprecatedEof))
            .concat([okPayload()]),
          [okPayload()]
        );

        try {
          const result = await caller.call(['app', 'mixed_results'], [
            procedureParameter(MySqlParameterDirection.In, 10),
            procedureParameter(MySqlParameterDirection.Out, 20),
            procedureParameter(MySqlParameterDirection.InOut, 30)
          ]);

          expect(result.results.length).assertEqual(4);
          expect(result.results[0].rows[0][0]).assertEqual(11);
          expect(result.results[1].rows[0][0]).assertEqual(22);
          expect(result.results[0].additionalResults.length).assertEqual(3);
          expect(result.outResultIndex).assertEqual(2);
          expect(result.results[2].columns[0].name).assertEqual('p_out');
          expect(result.results[2].columns[1].name).assertEqual('p_inout');
          expect(result.outValues.length).assertEqual(2);
          expect(result.outValues[0]).assertEqual(200);
          expect(result.outValues[1]).assertEqual(300);
          expect(result.results[3].columns.length).assertEqual(0);
          expect(result.results[3].rows.length).assertEqual(0);
          expect((fixture.clientCapabilities & Capabilities.PS_MULTI_RESULTS) !== 0).assertTrue();
          expect((fixture.clientCapabilities & Capabilities.MULTI_STATEMENTS) === 0).assertTrue();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
          expect(preparedSql(fixture)).assertEqual('CALL `app`.`mixed_results`(?,?,?)');
          await fixture.connection.ping();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
        } finally {
          await fixture.close();
        }
      }
    });

    it('outNullIsNotZero', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(8, 1),
        binaryNullResult('nullable_out',
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT)
          .concat([okPayload()])
      );

      try {
        const result = await caller.call(['nullable_out'], [
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Int32, 0))
        ]);

        expect(result.results.length).assertEqual(2);
        expect(result.outResultIndex).assertEqual(0);
        expect(result.results[0].columns[0].type).assertEqual(ColumnType.LONG);
        expect(result.outValues.length).assertEqual(1);
        expect(result.outValues[0] === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('pureOutUsesTypedNullBindingWithoutValueBytes', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(21, 3),
        binaryIntResult(['p_out', 'p_inout'], [200, 300],
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT, false).concat([okPayload()])
      );

      try {
        await caller.call(['typed_out'], [
          procedureParameter(MySqlParameterDirection.In, 10),
          procedureParameter(MySqlParameterDirection.Out, 999),
          procedureParameter(MySqlParameterDirection.InOut, 30)
        ]);

        expect(hex(executionFrame(fixture).subarray(4))).assertEqual(
          '1715000000000100000002010300030003000a0000001e000000');
      } finally {
        await fixture.close();
      }
    });

    it('missingOutMarkerFailsExplicitly', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
      fixture.peer.responses.push(
        prepareResponse(9, 1),
        binaryIntResult(['unmarked_out'], [7], 0, more, false)
          .concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: ArkDbError | null = await preparedFailureOf(caller.call(
          ['missing_marker'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Expected the completed procedure protocol failure.');
        }
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.message.indexOf('SERVER_PS_OUT_PARAMS') >= 0).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');

        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('noOutCallPreservesOrdinaryResultsAndFinalStatus', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
      fixture.peer.responses.push(
        prepareResponse(10),
        binaryIntResult(['first'], [1], 0, more, false)
          .concat(binaryIntResult(['second'], [2], 0, more, false))
          .concat([okPayload()])
      );

      try {
        const result = await caller.call(['no_outputs'], []);

        expect(result.results.length).assertEqual(3);
        expect(result.results[0].rows[0][0]).assertEqual(1);
        expect(result.results[1].rows[0][0]).assertEqual(2);
        expect(result.outResultIndex).assertEqual(-1);
        expect(result.outValues.length).assertEqual(0);
        expect(result.results[2].rows.length).assertEqual(0);
        expect(result.results[2].affectedRowsExact === 0n).assertTrue();
        expect(preparedSql(fixture)).assertEqual('CALL `no_outputs`()');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('outputColumnCountMismatchFailsAfterDrain', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(11, 1),
        binaryIntResult(['first', 'unexpected'], [1, 2],
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT, false).concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['wrong_count'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ]));

        expect(failure.message.indexOf('column count') >= 0).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('outputTypeAndSignednessMustMatchDeclaredParameters', 0, async () => {
      for (let mismatch = 0; mismatch < 2; mismatch += 1) {
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
        await fixture.open();
        const caller: MySqlProcedureCaller = procedureFeature(fixture);
        const response: Uint8Array[] = mismatch === 0 ?
          binaryTextResult('wrong_type', '7',
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT) :
          binaryLongResult('wrong_signedness', 7n, 0,
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT);
        const parameter: MySqlProcedureArgument = mismatch === 0 ?
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Int32, 0)) :
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.UInt64, 0n));
        fixture.peer.responses.push(
          prepareResponse(12 + mismatch, 1),
          response.concat([okPayload()]),
          [okPayload()]
        );

        try {
          const failure: MySqlOperationError = await completedProcedureFailure(
            caller.call(['metadata_mismatch'], [parameter]));

          expect(failure.message.indexOf('metadata') >= 0).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          await fixture.connection.ping();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
        } finally {
          await fixture.close();
        }
      }
    });

    it('unsupportedServerRejectsBeforePrepareWithoutTextFallback', 0, async () => {
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);

      try {
        const failure: ArkDbError | null = await preparedFailureOf(
          caller.call(['unsupported_procedure'], []));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Expected the unsupported prepared CALL failure.');
        }
        expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.commands().length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('duplicateOutMarkersFailAfterCompleteDrain', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(14, 1),
        binaryIntResult(['first_out'], [1],
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT, false)
          .concat(binaryIntResult(['second_out'], [2],
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT, false))
          .concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['duplicate_marker'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ]));

        expect(failure.message.indexOf('multiple SERVER_PS_OUT_PARAMS') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('outMarkerOnOkResultFailsAfterCompleteDrain', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const markedMore = StatusFlags.AUTOCOMMIT |
        StatusFlags.MORE_RESULTS_EXISTS | StatusFlags.PS_OUT_PARAMS;
      fixture.peer.responses.push(
        prepareResponse(15, 1),
        [okPayload(markedMore), okPayload()],
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['marker_on_ok'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ]));

        expect(failure.message.indexOf('row result') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('outputResultRequiresExactlyOneRow', 0, async () => {
      for (let rowCase = 0; rowCase < 2; rowCase += 1) {
        const fixture = new PreparedExecutionFixture(
          Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
        await fixture.open();
        const caller: MySqlProcedureCaller = procedureFeature(fixture);
        const response: Uint8Array[] = rowCase === 0 ?
          binaryNoRowResult('out_value',
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT) :
          binaryIntRowsResult('out_value', [1, 2],
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT);
        fixture.peer.responses.push(
          prepareResponse(16 + rowCase, 1),
          response.concat([okPayload()]),
          [okPayload()]
        );

        try {
          const failure: MySqlOperationError = await completedProcedureFailure(
            caller.call(['wrong_cardinality'], [
              procedureParameter(MySqlParameterDirection.Out, 0)
            ]));

          expect(failure.message.indexOf('exactly one') >= 0).assertTrue();
          await fixture.connection.ping();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
        } finally {
          await fixture.close();
        }
      }
    });

    it('truncatedTwoRowOutCannotPassCardinalityValidation', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const options = new QueryOptions();
      options.maxRows = 1;
      fixture.peer.responses.push(
        prepareResponse(24, 1),
        binaryIntRowsResult('out_value', [1, 2],
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT).concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['truncated_cardinality'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ], options));

        expect(failure.message.indexOf('exactly one known row') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('globalResultByteBudgetCannotYieldOutValues', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const options = new QueryOptions();
      options.maxResultBytes = 8;
      const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
      fixture.peer.responses.push(
        prepareResponse(25, 1),
        binaryIntResult(['ordinary'], [11], 0, more, false)
          .concat(binaryIntResult(['out_value'], [200],
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT, false))
          .concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['out_exceeds_global_budget'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ], options));

        expect(failure.message.indexOf('truncated') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('ordinaryTruncationBeforeOutCannotProduceOutputs', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      const options = new QueryOptions();
      options.maxRows = 1;
      const more = StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS;
      fixture.peer.responses.push(
        prepareResponse(26, 1),
        binaryIntRowsResult('ordinary', [10, 20], 0, more)
          .concat(binaryIntResult(['out_value'], [200],
            StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
            StatusFlags.AUTOCOMMIT, false))
          .concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['ordinary_truncates_before_out'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ], options));

        expect(failure.message.indexOf('truncated') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('missingFinalOkFailsAfterMarkedResultIsConsumed', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(18, 1),
        binaryIntResult(['out_value'], [1], StatusFlags.PS_OUT_PARAMS,
          StatusFlags.AUTOCOMMIT, false),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          caller.call(['missing_final_ok'], [
            procedureParameter(MySqlParameterDirection.Out, 0)
          ]));

        expect(failure.message.indexOf('final unmarked OK') >= 0).assertTrue();
        await fixture.connection.ping();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await fixture.close();
      }
    });

    it('outAndInOutRejectUntypedNullDeclarations', 0, () => {
      for (const direction of [
        MySqlParameterDirection.Out,
        MySqlParameterDirection.InOut
      ]) {
        let failure: Object | null = null;
        try {
          new MySqlProcedureArgument(direction,
            new MySqlParameter(MySqlParameterType.Null, null));
        } catch (error) {
          failure = error as Object;
        }
        expect(failure instanceof ArkDbError).assertTrue();
        if (!(failure instanceof ArkDbError)) {
          throw new Error('Expected untyped procedure output rejection.');
        }
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('textAndBinaryOutputsUseColumnCharsetWithBlobTypeCodes', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(19, 2),
        binaryTextAndBytesResult(
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT)
          .concat([okPayload()])
      );

      try {
        const result = await caller.call(['typed_blobs'], [
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Text, null)),
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Binary, null))
        ]);

        expect(result.outResultIndex).assertEqual(0);
        expect(result.outValues[0]).assertEqual('hello');
        const bytes: MySqlValue = result.outValues[1];
        expect(bytes instanceof Uint8Array).assertTrue();
        if (!(bytes instanceof Uint8Array)) throw new Error('Expected binary procedure output.');
        expect(bytes.length).assertEqual(2);
        expect(bytes[0]).assertEqual(1);
        expect(bytes[1]).assertEqual(2);
      } finally {
        await fixture.close();
      }
    });

    it('outputTypeValidationMatchesBinaryRowDecoding', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(
        prepareResponse(22, 3),
        binaryClassificationResult(
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT).concat([okPayload()])
      );

      try {
        const result = await caller.call(['classified_outputs'], [
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Text, null)),
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Binary, null)),
          new MySqlProcedureArgument(MySqlParameterDirection.Out,
            new MySqlParameter(MySqlParameterType.Binary, null))
        ]);

        expect(result.outValues[0]).assertEqual('flagged-text');
        assertBytes(result.outValues[1], 1, 2);
        assertBytes(result.outValues[2], 0xaa, 0x55);
      } finally {
        await fixture.close();
      }

      const mismatch = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await mismatch.open();
      const mismatchedCaller: MySqlProcedureCaller = procedureFeature(mismatch);
      mismatch.peer.responses.push(
        prepareResponse(23, 1),
        binaryFlaggedTextResult(
          StatusFlags.PS_OUT_PARAMS | StatusFlags.MORE_RESULTS_EXISTS,
          StatusFlags.AUTOCOMMIT).concat([okPayload()]),
        [okPayload()]
      );

      try {
        const failure: MySqlOperationError = await completedProcedureFailure(
          mismatchedCaller.call(['flagged_text_is_not_bytes'], [
            new MySqlProcedureArgument(MySqlParameterDirection.Out,
              new MySqlParameter(MySqlParameterType.Binary, null))
          ]));

        expect(failure.message.indexOf('metadata') >= 0).assertTrue();
        await mismatch.connection.ping();
        expect(mismatch.peer.commands().join(',')).assertEqual('22,23,25,14');
      } finally {
        await mismatch.close();
      }
    });

    it('procedureIdentifierRejectsMoreThanSchemaAndRoutine', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const caller: MySqlProcedureCaller = procedureFeature(fixture);
      fixture.peer.responses.push(prepareResponse(20), [okPayload()]);

      try {
        const failure: ArkDbError | null = await preparedFailureOf(
          caller.call(['catalog', 'schema', 'routine'], []));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Expected invalid routine identifier rejection.');
        }
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.commands().length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });
  });
}

function procedureFeature(fixture: PreparedExecutionFixture): MySqlProcedureCaller {
  const caller: MySqlProcedureCaller | undefined = fixture.connection.mysqlFeatures.procedures;
  if (caller === undefined) throw new Error('Expected the public procedure caller.');
  return caller;
}

function procedureParameter(direction: MySqlParameterDirection,
  value: number): MySqlProcedureArgument {
  return new MySqlProcedureArgument(direction,
    new MySqlParameter(MySqlParameterType.Int32, value));
}

function binaryIntResult(names: string[], values: number[], metadataFlags: number,
  completionFlags: number, deprecatedEof: boolean): Uint8Array[] {
  const packets: Uint8Array[] = [new PacketWriter().writeLenEncInt(names.length).toUint8Array()];
  for (const name of names) packets.push(columnPayload(name, ColumnType.LONG));
  if (!deprecatedEof) packets.push(eofPayload(metadataFlags));
  const row = new PacketWriter().writeUInt8(0).writeZeroes(Math.ceil((names.length + 2) / 8));
  for (const value of values) row.writeInt32(value);
  packets.push(row.toUint8Array());
  packets.push(deprecatedEof ?
    resultOkPayload(completionFlags | metadataFlags) : eofPayload(completionFlags));
  return packets;
}

function binaryNullResult(name: string, metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name, ColumnType.LONG),
    eofPayload(metadataFlags),
    new Uint8Array([0, 4]),
    eofPayload(completionFlags)
  ];
}

function binaryTextResult(name: string, value: string, metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name, ColumnType.VAR_STRING),
    eofPayload(metadataFlags),
    new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeLenEncString(value).toUint8Array(),
    eofPayload(completionFlags)
  ];
}

function binaryLongResult(name: string, value: bigint, columnFlags: number,
  metadataFlags: number, completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name, ColumnType.LONGLONG, columnFlags),
    eofPayload(metadataFlags),
    new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeUInt64(value).toUint8Array(),
    eofPayload(completionFlags)
  ];
}

function binaryNoRowResult(name: string, metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name, ColumnType.LONG),
    eofPayload(metadataFlags),
    eofPayload(completionFlags)
  ];
}

function binaryIntRowsResult(name: string, values: number[],
  metadataFlags: number, completionFlags: number): Uint8Array[] {
  const packets: Uint8Array[] = [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name, ColumnType.LONG),
    eofPayload(metadataFlags)
  ];
  for (const value of values) {
    packets.push(new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeInt32(value).toUint8Array());
  }
  packets.push(eofPayload(completionFlags));
  return packets;
}

function binaryTextAndBytesResult(metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(2).toUint8Array(),
    columnPayload('text_out', ColumnType.BLOB, 0, 0, 45),
    columnPayload('binary_out', ColumnType.BLOB, 0, 0, 63),
    eofPayload(metadataFlags),
    new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeLenEncString('hello').writeLenEncBytes(new Uint8Array([1, 2]))
      .toUint8Array(),
    eofPayload(completionFlags)
  ];
}

function binaryClassificationResult(metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(3).toUint8Array(),
    columnPayload('flagged_text', ColumnType.VAR_STRING,
      FieldFlag.BINARY, 0, 45),
    columnPayload('binary_charset', ColumnType.VAR_STRING, 0, 0, 63),
    columnPayload('intrinsic_binary', ColumnType.BIT, 0, 0, 45),
    eofPayload(metadataFlags),
    new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeLenEncString('flagged-text')
      .writeLenEncBytes(new Uint8Array([1, 2]))
      .writeLenEncBytes(new Uint8Array([0xaa, 0x55]))
      .toUint8Array(),
    eofPayload(completionFlags)
  ];
}

function binaryFlaggedTextResult(metadataFlags: number,
  completionFlags: number): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload('flagged_text', ColumnType.VAR_STRING,
      FieldFlag.BINARY, 0, 45),
    eofPayload(metadataFlags),
    new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeLenEncString('flagged-text').toUint8Array(),
    eofPayload(completionFlags)
  ];
}

function eofPayload(flags: number): Uint8Array {
  return new PacketWriter().writeUInt8(0xfe).writeUInt16(0)
    .writeUInt16(flags).toUint8Array();
}

function resultOkPayload(flags: number): Uint8Array {
  return new PacketWriter().writeUInt8(0xfe).writeLenEncInt(0)
    .writeLenEncInt(0).writeUInt16(flags).writeUInt16(0).toUint8Array();
}

function preparedSql(fixture: PreparedExecutionFixture): string {
  for (const frame of fixture.peer.writes) {
    if (frame[4] === 0x16) return new PacketReader(frame.subarray(5)).readEofString();
  }
  throw new Error('Expected a prepared CALL command.');
}

function executionFrame(fixture: PreparedExecutionFixture): Uint8Array {
  for (const frame of fixture.peer.writes) {
    if (frame[4] === 0x17) return frame;
  }
  throw new Error('Expected a prepared CALL execution.');
}

function assertBytes(value: MySqlValue, first: number, second: number): void {
  expect(value instanceof Uint8Array).assertTrue();
  if (!(value instanceof Uint8Array)) throw new Error('Expected binary procedure output.');
  expect(value.length).assertEqual(2);
  expect(value[0]).assertEqual(first);
  expect(value[1]).assertEqual(second);
}

async function completedProcedureFailure(
  task: Promise<Object>): Promise<MySqlOperationError> {
  const failure: ArkDbError | null = await preparedFailureOf(task);
  expect(failure instanceof MySqlOperationError).assertTrue();
  if (!(failure instanceof MySqlOperationError)) {
    throw new Error('Expected a completed procedure protocol failure.');
  }
  expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
  expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
  return failure;
}
