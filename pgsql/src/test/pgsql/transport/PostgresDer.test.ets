import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresDerElement, PostgresDerReader
} from '../../../main/ets/pgsql/transport/PostgresDer';

export default function postgresDerTest(): void {
  describe('PostgresDer', () => {
    it('readsBoundedCanonicalDerElements', 0, () => {
      for (let length: number = 0; length <= 0x7f; length += 1) {
        assertElement(payloadElement([0x04, length], length),
          0x04, 2, length + 2);
      }
      assertElement(payloadElement([0x04, 0x81, 0x80], 0x80), 0x04, 3, 0x83);
      assertElement(payloadElement([0x04, 0x82, 0x01, 0x00], 0x100),
        0x04, 4, 0x104);
      assertElement(payloadElement([0x04, 0x83, 0x01, 0x00, 0x00], 0x10000),
        0x04, 5, 0x10005);
      assertElement(payloadElement(
        [0x04, 0x84, 0x01, 0x00, 0x00, 0x00], 0x1000000),
        0x04, 6, 0x1000006);
      const expected = new PostgresDerReader(
        new Uint8Array([0x05, 0x00]), 2, 1).expected(0, 2, 0x05);
      expect(expected.tag).assertEqual(0x05);
    });

    it('rejectsMalformedDerIdentifiersLengthsAndBounds', 0, () => {
      const malformed: Uint8Array[] = [
        new Uint8Array([0x04, 0x80]),
        new Uint8Array([0x04, 0x82, 0x00, 0x80]),
        payloadElement([0x04, 0x81, 0x7f], 0x7f),
        new Uint8Array([0x04, 0x85, 0, 0, 0, 0, 0]),
        new Uint8Array([0x04]),
        new Uint8Array([0x04, 0x82, 0x01]),
        new Uint8Array([0x04, 0x01]),
        new Uint8Array([0x04, 0x84, 0xff, 0xff, 0xff, 0xff]),
        new Uint8Array([0x00, 0x00]),
        new Uint8Array([0x1f, 0x00]),
        new Uint8Array([0x3f, 0x00])
      ];
      for (const encoded of malformed) expectReadFailure(encoded);
      const reader = new PostgresDerReader(
        new Uint8Array([0x05, 0x00]), 2, 1);
      expectDerFailure((): void => { reader.expected(0, 2, 0x04); });
      expectDerFailure((): void => { reader.read(-1, 2); });
      expectDerFailure((): void => { reader.read(0.5, 2); });
      expectDerFailure((): void => { reader.read(0, 3); });
      expectDerFailure((): void => { reader.read(2, 1); });
      expectDerFailure((): void => {
        new PostgresDerReader(new Uint8Array(2), 1, 1);
      });
      for (const limits of [[0, 1], [1.5, 1], [1, 0], [1, 1.5]]) {
        expectDerFailure((): void => {
          new PostgresDerReader(new Uint8Array(0), limits[0], limits[1]);
        });
      }
      expectDerFailure((): void => {
        new PostgresDerReader(new Uint8Array(0), 1, 33);
      });
    });

    it('validatesUniversalPrimitiveAndStringEncodings', 0, () => {
      const valid: Uint8Array[] = [
        bytes([0x01, 0x01, 0x00]), bytes([0x01, 0x01, 0xff]),
        bytes([0x02, 0x01, 0x00]), bytes([0x02, 0x02, 0x00, 0x80]),
        bytes([0x0a, 0x01, 0xff]), bytes([0x03, 0x01, 0x00]),
        bytes([0x03, 0x02, 0x03, 0xf8]), bytes([0x04, 0x01, 0xff]),
        bytes([0x05, 0x00]), bytes([0x06, 0x02, 0x2a, 0x03]),
        bytes([0x06, 0x03, 0x81, 0x00, 0x01]),
        bytes([0x0c, 0x03, 0xe2, 0x82, 0xac]),
        bytes([0x0c, 0x04, 0xf0, 0x9f, 0x98, 0x80]),
        textElement(0x12, ' 0123456789'),
        textElement(0x13, "AZaz09 '()+,-./:=?"),
        bytes([0x14, 0x01, 0x41]), bytes([0x16, 0x02, 0x00, 0x7f]),
        bytes([0x1c, 0x04, 0x00, 0x01, 0xf6, 0x00]),
        bytes([0x1e, 0x02, 0x00, 0x41])
      ];
      for (const encoded of valid) validate(encoded);
      const invalid: Uint8Array[] = [
        bytes([0x01, 0x00]), bytes([0x01, 0x01, 0x01]),
        bytes([0x02, 0x00]), bytes([0x02, 0x02, 0x00, 0x7f]),
        bytes([0x02, 0x02, 0xff, 0x80]), bytes([0x03, 0x00]),
        bytes([0x03, 0x01, 0x08]), bytes([0x03, 0x02, 0x03, 0xff]),
        bytes([0x05, 0x01, 0x00]), bytes([0x06, 0x00]),
        bytes([0x06, 0x01, 0x80]), bytes([0x06, 0x01, 0x81]),
        bytes([0x0c, 0x02, 0xc0, 0xaf]), bytes([0x0c, 0x03, 0xed, 0xa0, 0x80]),
        bytes([0x0c, 0x04, 0xf4, 0x90, 0x80, 0x80]),
        bytes([0x0c, 0x02, 0xe2, 0x82]),
        bytes([0x0c, 0x03, 0xe2, 0x28, 0xa1]), textElement(0x12, 'A'),
        textElement(0x13, '@'), bytes([0x16, 0x01, 0x80]),
        bytes([0x1c, 0x03, 0x00, 0x00, 0x00]),
        bytes([0x1c, 0x04, 0x00, 0x00, 0xd8, 0x00]),
        bytes([0x1c, 0x04, 0x00, 0x11, 0x00, 0x00]),
        bytes([0x1e, 0x01, 0x00]), bytes([0x1e, 0x02, 0xd8, 0x00])
      ];
      expectValueFailures(invalid);
      const validTimes: Uint8Array[] = [
        textElement(0x17, '240229235959Z'),
        textElement(0x17, '500101000000Z'),
        textElement(0x18, '20000229000000Z'),
        textElement(0x18, '20000229010203Z')
      ];
      for (const encoded of validTimes) validate(encoded);
      const invalidTimes: Uint8Array[] = [
        textElement(0x17, '230229000000Z'),
        textElement(0x17, '241300000000Z'),
        textElement(0x17, '240431000000Z'),
        textElement(0x17, '240101240000Z'),
        textElement(0x17, '240101006000Z'),
        textElement(0x17, '240101000060Z'),
        textElement(0x18, '19000229000000Z'),
        textElement(0x18, '2000010100000Z')
      ];
      expectValueFailures(invalidTimes);
    });

    it('validatesTeletexStateTransitions', 0, () => {
      const valid: Uint8Array[] = [
        bytes([0x14, 0x08, 0x20, 0x21, 0x5b, 0x5d, 0x5f, 0x61, 0x7a, 0x7c]),
        bytes([0x14, 0x08, 0xa1, 0xa8, 0xaa, 0xb0, 0xb8, 0xbb, 0xe0, 0xfe]),
        bytes([0x14, 0x04, 0xc2, 0x41, 0xc2, 0x20]),
        bytes([0x14, 0x1a, 0xc1, 0x41, 0xc2, 0x43, 0xc3, 0x45,
          0xc4, 0x49, 0xc5, 0x4f, 0xc6, 0x55, 0xc7, 0x5a,
          0xc8, 0x59, 0xca, 0x41, 0xcb, 0x43, 0xcd, 0x4f,
          0xce, 0x55, 0xcf, 0x5a]),
        bytes([0x14, 0x06, 0xc2, 0x67, 0xc7, 0x49, 0xcb, 0x47]),
        bytes([0x14, 0x04, 0x1b, 0x28, 0x75, 0x41]),
        bytes([0x14, 0x08, 0x1b, 0x28, 0x76, 0x21,
          0x1b, 0x28, 0x75, 0x41]),
        bytes([0x14, 0x07, 0x1b, 0x21, 0x45,
          0x1b, 0x22, 0x48, 0x41])
      ];
      for (const encoded of valid) validate(encoded);
      expectAllValueFailures([
        bytes([0x14, 0x01, 0x1b]),
        bytes([0x14, 0x02, 0x1b, 0x28]),
        bytes([0x14, 0x03, 0x1b, 0x28, 0x42]),
        bytes([0x14, 0x03, 0x1b, 0x29, 0x75]),
        bytes([0x14, 0x01, 0x0a]),
        bytes([0x14, 0x01, 0x5c]), bytes([0x14, 0x01, 0x60]),
        bytes([0x14, 0x01, 0x7e]), bytes([0x14, 0x01, 0xa9]),
        bytes([0x14, 0x01, 0xb9]), bytes([0x14, 0x01, 0xc0]),
        bytes([0x14, 0x01, 0xc9]), bytes([0x14, 0x01, 0xcc]),
        bytes([0x14, 0x01, 0xd0]), bytes([0x14, 0x01, 0xe5]),
        bytes([0x14, 0x01, 0xe9]), bytes([0x14, 0x01, 0xff]),
        bytes([0x14, 0x04, 0x1b, 0x28, 0x76, 0x40]),
        bytes([0x14, 0x01, 0xc2]), bytes([0x14, 0x02, 0xc2, 0x30]),
        bytes([0x14, 0x02, 0xc1, 0x42]), bytes([0x14, 0x02, 0xc2, 0x42]),
        bytes([0x14, 0x02, 0xc3, 0x42]), bytes([0x14, 0x02, 0xc4, 0x42]),
        bytes([0x14, 0x02, 0xc5, 0x42]), bytes([0x14, 0x02, 0xc6, 0x42]),
        bytes([0x14, 0x02, 0xc7, 0x42]), bytes([0x14, 0x02, 0xc8, 0x42]),
        bytes([0x14, 0x02, 0xca, 0x42]), bytes([0x14, 0x02, 0xcb, 0x42]),
        bytes([0x14, 0x02, 0xcd, 0x42]), bytes([0x14, 0x02, 0xce, 0x42]),
        bytes([0x14, 0x02, 0xcf, 0x42]),
        bytes([0x14, 0x02, 0xc2, 0x47]),
        bytes([0x14, 0x02, 0xc7, 0x69]),
        bytes([0x14, 0x02, 0xcb, 0x67]),
        bytes([0x14, 0x07, 0x1b, 0x28, 0x76, 0x42,
          0x1b, 0x28, 0x75])
      ]);
    });

    it('enforcesDerDepthCopiesAndRangeOrdering', 0, () => {
      validate(bytes([0x30, 0x02, 0x05, 0x00]));
      validate(bytes([0x31, 0x02, 0x05, 0x00]));
      validate(bytes([0x80, 0x01, 0xff]));
      validate(bytes([0xa0, 0x02, 0x05, 0x00]));
      validate(bytes([0x60, 0x02, 0x05, 0x00]));
      expectValueFailures([
        bytes([0x07, 0x00]), bytes([0x21, 0x00]),
        bytes([0x2c, 0x02, 0x05, 0x00]),
        bytes([0x30, 0x03, 0x05, 0x00, 0x00])
      ]);
      validate(nestedSequences(32), 32);
      expectValueFailure(nestedSequences(33), 32);
      validate(manyNulls(65535), 32);
      expectValueFailure(manyNulls(65536), 32);
      const foreignReader = new PostgresDerReader(
        new Uint8Array([0x04, 0x01, 0xff]), 3, 1);
      const foreign = foreignReader.read(0, 3);
      const targetReader = new PostgresDerReader(
        new Uint8Array([0x01, 0x01, 0x01]), 3, 1);
      expectDerFailure((): void => { targetReader.validateValue(foreign, 0); });
      expectDerFailure((): void => {
        targetReader.validateValue(
          new PostgresDerElement(0x04, 0, 2.5, 3), 0);
      });
      const source = new Uint8Array([0x04, 0x02, 0xaa, 0xbb]);
      const reader = new PostgresDerReader(source, source.length, 32);
      source[2] = 0xff;
      const value = reader.read(0, 4);
      const copy = reader.copy(value.start, value.end);
      assertNumbers(copy, [0xaa, 0xbb]);
      copy[0] = 0;
      assertNumbers(reader.copy(value.start, value.end), [0xaa, 0xbb]);
      expectDerFailure((): void => { reader.copy(-1, 1); });
      expectDerFailure((): void => { reader.copy(2, 1); });
      expectDerFailure((): void => { reader.copy(0, 5); });
      const ranges = new PostgresDerReader(
        new Uint8Array([1, 2, 1, 2, 3, 2]), 6, 1);
      expect(ranges.compare(0, 2, 2, 4)).assertEqual(0);
      expect(ranges.compare(0, 2, 2, 5) < 0).assertTrue();
      expect(ranges.compare(2, 5, 0, 2) > 0).assertTrue();
      expect(ranges.compare(0, 2, 5, 6) < 0).assertTrue();
      expectDerFailure((): void => { ranges.compare(-1, 1, 0, 1); });
    });
  });
}

function assertElement(encoded: Uint8Array, tag: number,
  start: number, next: number): void {
  const reader = new PostgresDerReader(encoded, encoded.length, 32);
  const value = reader.read(0, encoded.length);
  expect(value instanceof PostgresDerElement).assertTrue();
  expect(value.tag).assertEqual(tag);
  expect(value.offset).assertEqual(0);
  expect(value.start).assertEqual(start);
  expect(value.end).assertEqual(next);
  expect(value.next).assertEqual(next);
}

function validate(encoded: Uint8Array, maximumDepth: number = 32): void {
  const reader = new PostgresDerReader(encoded, encoded.length, maximumDepth);
  const value = reader.read(0, encoded.length);
  expect(value.next).assertEqual(encoded.length);
  reader.validateValue(value, 0);
}

function expectReadFailure(encoded: Uint8Array): void {
  expectDerFailure((): void => {
    new PostgresDerReader(encoded, encoded.length, 32)
      .read(0, encoded.length);
  });
}

function expectValueFailure(encoded: Uint8Array,
  maximumDepth: number = 32): void {
  expectDerFailure((): void => { validate(encoded, maximumDepth); });
}

function expectValueFailures(encoded: Uint8Array[]): void {
  for (const value of encoded) expectValueFailure(value);
}

function expectAllValueFailures(encoded: Uint8Array[]): void {
  let rejected: number = 0;
  for (const value of encoded) {
    try {
      validate(value);
    } catch (error) {
      const terminal = error as ArkDbError;
      expect(terminal instanceof ArkDbError).assertTrue();
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(terminal.nativeCode).assertEqual(
        'TLS_CERTIFICATE_IDENTITY_INVALID');
      rejected += 1;
    }
  }
  expect(rejected).assertEqual(encoded.length);
}

function expectDerFailure(operation: () => void): void {
  let terminal: ArkDbError | null = null;
  try {
    operation();
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.nativeCode).assertEqual(
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}

function payloadElement(header: number[], length: number): Uint8Array {
  const encoded = new Uint8Array(header.length + length);
  encoded.set(new Uint8Array(header), 0);
  return encoded;
}

function textElement(tag: number, value: string): Uint8Array {
  const encoded = new Uint8Array(value.length + 2);
  encoded[0] = tag;
  encoded[1] = value.length;
  for (let index = 0; index < value.length; index += 1) {
    encoded[index + 2] = value.charCodeAt(index);
  }
  return encoded;
}

function nestedSequences(depth: number): Uint8Array {
  const encoded = new Uint8Array(depth * 2 + 2);
  for (let index = 0; index < depth; index += 1) {
    encoded[index * 2] = 0x30;
    encoded[index * 2 + 1] = (depth - index - 1) * 2 + 2;
  }
  encoded[depth * 2] = 0x05;
  return encoded;
}

function manyNulls(count: number): Uint8Array {
  const contentLength = count * 2;
  const encoded = new Uint8Array(contentLength + 5);
  encoded.set(new Uint8Array([
    0x30, 0x83, (contentLength >>> 16) & 0xff,
    (contentLength >>> 8) & 0xff, contentLength & 0xff
  ]));
  for (let index = 0; index < count; index += 1) {
    encoded[5 + index * 2] = 0x05;
  }
  return encoded;
}

function bytes(values: number[]): Uint8Array {
  return new Uint8Array(values);
}

function assertNumbers(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
