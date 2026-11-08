import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresFrontendSerializer, PostgresFrontendTarget, PostgresStartupParameter
} from '../../../main/ets/pgsql/protocol/PostgresByteCodec';

export default function postgresFrontendSerializerTest(): void {
  describe('PostgresFrontendSerializer', () => {
    it('serializesUntypedStartupSslAndCancelVectors', 0, () => {
      assertBytes(PostgresFrontendSerializer.sslRequest(), [
        0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f
      ]);
      const parameters: PostgresStartupParameter[] = [
        { name: 'user', value: 'alice' },
        { name: 'database', value: 'app' }
      ];
      assertBytes(PostgresFrontendSerializer.startup(parameters), [
        0x00, 0x00, 0x00, 0x21, 0x00, 0x03, 0x00, 0x00,
        0x75, 0x73, 0x65, 0x72, 0x00,
        0x61, 0x6c, 0x69, 0x63, 0x65, 0x00,
        0x64, 0x61, 0x74, 0x61, 0x62, 0x61, 0x73, 0x65, 0x00,
        0x61, 0x70, 0x70, 0x00, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.cancelRequest(-2147483648, 2147483647), [
        0x00, 0x00, 0x00, 0x10, 0x04, 0xd2, 0x16, 0x2e,
        0x80, 0x00, 0x00, 0x00, 0x7f, 0xff, 0xff, 0xff
      ]);
    });

    it('serializesPasswordAndSaslVectors', 0, () => {
      assertBytes(PostgresFrontendSerializer.password('secret'), [
        0x70, 0x00, 0x00, 0x00, 0x0b,
        0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.saslInitialResponse(
        'SCRAM-SHA-256', new Uint8Array([0x61, 0x62, 0x63])), [
        0x70, 0x00, 0x00, 0x00, 0x19,
        0x53, 0x43, 0x52, 0x41, 0x4d, 0x2d, 0x53, 0x48, 0x41, 0x2d, 0x32, 0x35, 0x36, 0x00,
        0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63
      ]);
      assertBytes(PostgresFrontendSerializer.saslInitialResponse('SCRAM-SHA-256', null), [
        0x70, 0x00, 0x00, 0x00, 0x16,
        0x53, 0x43, 0x52, 0x41, 0x4d, 0x2d, 0x53, 0x48, 0x41, 0x2d, 0x32, 0x35, 0x36, 0x00,
        0xff, 0xff, 0xff, 0xff
      ]);
      assertBytes(PostgresFrontendSerializer.saslInitialResponse(
        'SCRAM-SHA-256', new Uint8Array(0)), [
        0x70, 0x00, 0x00, 0x00, 0x16,
        0x53, 0x43, 0x52, 0x41, 0x4d, 0x2d, 0x53, 0x48, 0x41, 0x2d, 0x32, 0x35, 0x36, 0x00,
        0x00, 0x00, 0x00, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.saslResponse(new Uint8Array([0xcf, 0x80])), [
        0x70, 0x00, 0x00, 0x00, 0x06, 0xcf, 0x80
      ]);
    });

    it('serializesQueryAndParseVectors', 0, () => {
      assertBytes(PostgresFrontendSerializer.query('select π'), [
        0x51, 0x00, 0x00, 0x00, 0x0e,
        0x73, 0x65, 0x6c, 0x65, 0x63, 0x74, 0x20, 0xcf, 0x80, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.parse('s', 'select $1', [23, 4294967295]), [
        0x50, 0x00, 0x00, 0x00, 0x1a,
        0x73, 0x00,
        0x73, 0x65, 0x6c, 0x65, 0x63, 0x74, 0x20, 0x24, 0x31, 0x00,
        0x00, 0x02,
        0x00, 0x00, 0x00, 0x17, 0xff, 0xff, 0xff, 0xff
      ]);
      assertBytes(PostgresFrontendSerializer.parse('', '', []), [
        0x50, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00
      ]);
    });

    it('serializesBindNullEmptyAndBinaryParameters', 0, () => {
      const parameters: Array<Uint8Array | null> = [
        null, new Uint8Array(0), new Uint8Array([0x61, 0x62])
      ];
      assertBytes(PostgresFrontendSerializer.bind('p', 's', [0, 1, 0], parameters, [1]), [
        0x42, 0x00, 0x00, 0x00, 0x24,
        0x70, 0x00, 0x73, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x03,
        0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x61, 0x62,
        0x00, 0x01, 0x00, 0x01
      ]);
      assertBytes(PostgresFrontendSerializer.bind('', '', [], [], []), [
        0x42, 0x00, 0x00, 0x00, 0x0c,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
      ]);
    });

    it('serializesDescribeExecuteAndCloseVectors', 0, () => {
      assertBytes(PostgresFrontendSerializer.describe(PostgresFrontendTarget.Statement, 's'), [
        0x44, 0x00, 0x00, 0x00, 0x07, 0x53, 0x73, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.describe(PostgresFrontendTarget.Portal, ''), [
        0x44, 0x00, 0x00, 0x00, 0x06, 0x50, 0x00
      ]);
      assertBytes(PostgresFrontendSerializer.execute('p', 2147483647), [
        0x45, 0x00, 0x00, 0x00, 0x0a, 0x70, 0x00, 0x7f, 0xff, 0xff, 0xff
      ]);
      assertBytes(PostgresFrontendSerializer.close(PostgresFrontendTarget.Statement, ''), [
        0x43, 0x00, 0x00, 0x00, 0x06, 0x53, 0x00
      ]);
    });

    it('serializesControlAndCopyVectors', 0, () => {
      assertBytes(PostgresFrontendSerializer.flush(), [0x48, 0x00, 0x00, 0x00, 0x04]);
      assertBytes(PostgresFrontendSerializer.sync(), [0x53, 0x00, 0x00, 0x00, 0x04]);
      assertBytes(PostgresFrontendSerializer.terminate(), [0x58, 0x00, 0x00, 0x00, 0x04]);
      assertBytes(PostgresFrontendSerializer.copyDone(), [0x63, 0x00, 0x00, 0x00, 0x04]);
      assertBytes(PostgresFrontendSerializer.copyData(new Uint8Array([0x00, 0xff])), [
        0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0xff
      ]);
      assertBytes(PostgresFrontendSerializer.copyFail('stop'), [
        0x66, 0x00, 0x00, 0x00, 0x09, 0x73, 0x74, 0x6f, 0x70, 0x00
      ]);
    });

    it('rejectsInvalidNamesNulAndUnicodeBeforeEmission', 0, () => {
      assertValidation((): void => { PostgresFrontendSerializer.startup([]); });
      assertValidation((): void => {
        PostgresFrontendSerializer.startup([{ name: 'database', value: 'app' }]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.startup([{ name: 'user', value: '' }]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.startup([{ name: '', value: 'alice' }]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.startup([{ name: 'user\u0000x', value: 'alice' }]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.startup([{ name: 'user', value: 'a\u0000lice' }]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.saslInitialResponse('', new Uint8Array(0));
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.saslInitialResponse('SCRAM\u0000SHA', new Uint8Array(0));
      });
      assertValidation((): void => { PostgresFrontendSerializer.password('bad\u0000value'); });
      assertValidation((): void => { PostgresFrontendSerializer.query('select\u00001'); });
      assertValidation((): void => { PostgresFrontendSerializer.parse('s\u0000x', '', []); });
      assertValidation((): void => { PostgresFrontendSerializer.parse('', 'q\u0000x', []); });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('p\u0000x', '', [], [], []);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.describe(PostgresFrontendTarget.Statement, 's\u0000x');
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.close(PostgresFrontendTarget.Portal, 'p\u0000x');
      });
      assertValidation((): void => { PostgresFrontendSerializer.copyFail('bad\u0000value'); });
      assertValidation((): void => {
        PostgresFrontendSerializer.query(String.fromCharCode(0xd800));
      });
    });

    it('rejectsInvalidTargetsFormatsAndIntegerBounds', 0, () => {
      assertValidation((): void => {
        PostgresFrontendSerializer.describe(99 as PostgresFrontendTarget, '');
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.close(99 as PostgresFrontendTarget, '');
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [-1], [], []);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [2], [], []);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [], [], [2]);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [0, 1],
          [new Uint8Array(0), new Uint8Array(0), new Uint8Array(0)], []);
      });
      assertValidation((): void => { PostgresFrontendSerializer.execute('', -1); });
      assertValidation((): void => { PostgresFrontendSerializer.execute('', 2147483648); });
      assertValidation((): void => { PostgresFrontendSerializer.execute('', 0.5); });
      assertValidation((): void => {
        PostgresFrontendSerializer.cancelRequest(-2147483649, 0);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.cancelRequest(0, 2147483648);
      });
      assertValidation((): void => { PostgresFrontendSerializer.cancelRequest(0.5, 0); });
      assertValidation((): void => { PostgresFrontendSerializer.parse('', '', [-1]); });
      assertValidation((): void => {
        PostgresFrontendSerializer.parse('', '', [4294967296]);
      });
      assertValidation((): void => { PostgresFrontendSerializer.parse('', '', [0.5]); });
    });

    it('enforcesUnsignedProtocolCountLimitsAtTheBoundary', 0, () => {
      const maximumOids = repeatNumbers(65535, 0);
      const frame = PostgresFrontendSerializer.parse('', '', maximumOids);
      expect(frame.length).assertEqual(262149);
      assertBytes(frame.subarray(0, 9), [
        0x50, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0xff, 0xff
      ]);

      assertValidation((): void => {
        PostgresFrontendSerializer.parse('', '', repeatNumbers(65536, 0));
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', repeatNumbers(65536, 0), [], []);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [], repeatNulls(65536), []);
      });
      assertValidation((): void => {
        PostgresFrontendSerializer.bind('', '', [], [], repeatNumbers(65536, 0));
      });
    });

    it('acceptsTheCompleteMessageCapAndRejectsOneByteMore', 0, () => {
      const copyFrame = PostgresFrontendSerializer.copyData(new Uint8Array(33554428));
      expect(copyFrame.length).assertEqual(33554433);
      assertBytes(copyFrame.subarray(0, 5), [0x64, 0x02, 0x00, 0x00, 0x00]);
      assertValidation((): void => {
        PostgresFrontendSerializer.copyData(new Uint8Array(33554429));
      });

      const startupFrame = PostgresFrontendSerializer.startup(
        [{ name: 'user', value: 'a'.repeat(33554417) }]);
      expect(startupFrame.length).assertEqual(33554432);
      assertBytes(startupFrame.subarray(0, 8), [
        0x02, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00
      ]);
      assertValidation((): void => {
        PostgresFrontendSerializer.startup(
          [{ name: 'user', value: 'a'.repeat(33554418) }]);
      });
    });
  });
}

function repeatNumbers(count: number, value: number): number[] {
  const values: number[] = [];
  for (let index = 0; index < count; index += 1) values.push(value);
  return values;
}

function repeatNulls(count: number): Array<Uint8Array | null> {
  const values: Array<Uint8Array | null> = [];
  for (let index = 0; index < count; index += 1) values.push(null);
  return values;
}

function assertValidation(action: () => void): void {
  let failure: ArkDbError | null = null;
  try {
    action();
  } catch (error) {
    failure = error as ArkDbError;
  }
  expect(failure instanceof ArkDbError).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
