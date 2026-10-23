import { describe, it, expect } from '@ohos/hypium';
import { ColumnDef } from '../../../main/ets/core/model/QueryResult';
import { Collation, ColumnType } from '../../../main/ets/mysql/protocol/Constants';
import { mapDecodedTextValue, mapTextValue } from '../../../main/ets/mysql/value/TypeMapper';

export default function typeMapperTest() {
  describe('TypeMapper', () => {
    it('preservesExactTextProtocolValueKindsAfterUtf8Decode', 0, () => {
      expect(mapDecodedTextValue(column(ColumnType.VAR_STRING), '') as string).assertEqual('');
      expect(mapDecodedTextValue(column(ColumnType.VAR_STRING), 'NULL') as string).assertEqual('NULL');
      expect(mapDecodedTextValue(column(ColumnType.NEWDECIMAL), '12345678901234567890.1234567890') as string)
        .assertEqual('12345678901234567890.1234567890');
      expect((mapDecodedTextValue(column(ColumnType.LONGLONG), '-9223372036854775808') as bigint).toString())
        .assertEqual('-9223372036854775808');
      expect((mapDecodedTextValue(column(ColumnType.LONGLONG), '18446744073709551615') as bigint).toString())
        .assertEqual('18446744073709551615');
      expect(mapDecodedTextValue(column(ColumnType.DATE), '2026-07-20') as string)
        .assertEqual('2026-07-20');
      expect(mapDecodedTextValue(column(ColumnType.TIME), '-838:59:59.000001') as string)
        .assertEqual('-838:59:59.000001');
      expect(mapDecodedTextValue(column(ColumnType.DATETIME), '2026-07-20 09:30:45.123456') as string)
        .assertEqual('2026-07-20 09:30:45.123456');
      expect(mapDecodedTextValue(column(ColumnType.JSON), '{"value":null}') as string)
        .assertEqual('{"value":null}');
      const utf8mb4 = '\u9be8\uD83D\uDC2C';
      expect(mapDecodedTextValue(column(ColumnType.VAR_STRING), utf8mb4) as string)
        .assertEqual(utf8mb4);
    });

    it('preservesNullBlobAndBitBytes', 0, () => {
      const blobColumn = column(ColumnType.BLOB);
      blobColumn.charset = Collation.BINARY;
      const blob = new Uint8Array([0, 1, 127, 128, 254, 255]);
      const decodedBlob = mapTextValue(blobColumn, blob) as Uint8Array;
      expect(decodedBlob === blob).assertTrue();
      expect(decodedBlob.length).assertEqual(6);
      expect(decodedBlob[5]).assertEqual(255);

      const bit = new Uint8Array([0x80, 0x01]);
      const decodedBit = mapTextValue(column(ColumnType.BIT), bit) as Uint8Array;
      expect(decodedBit === bit).assertTrue();
      expect(mapTextValue(blobColumn, null) === null).assertTrue();
    });
  });
}

function column(type: number): ColumnDef {
  const value = new ColumnDef();
  value.type = type;
  return value;
}