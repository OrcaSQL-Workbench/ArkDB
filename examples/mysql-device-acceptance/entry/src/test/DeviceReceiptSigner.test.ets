import { describe, expect, it } from '@ohos/hypium';
import {
  deviceReceiptPayloadBytes, Ed25519DeviceReceiptSigner
} from '../main/ets/sample/DeviceReceiptSigner';

const PUBLIC_KEY: string = 'MCowBQYDK2VwAyEADb/Cqqww74MVIcezIun9Mh1lbnx3cw9Qy9vYztWx2NA=';
const PRIVATE_KEY: string = 'MC4CAQAwBQYDK2VwBCIEIPFypge0/4Q4Nj+g3rdkq1waRD/wmRetRJ4eUBT0D86S';
const PAYLOAD: string = '{"schemaVersion":1,"kind":"pooled-offset","value":"界"}';
const EXPECTED: string = '{"schemaVersion":1,"kind":"arkdb-device-acceptance-envelope",' +
  '"payload":"{\\"schemaVersion\\":1,\\"kind\\":\\"pooled-offset\\",\\"value\\":\\"界\\"}",' +
  '"signature":{"algorithm":"Ed25519","publicKeySpkiBase64":"' + PUBLIC_KEY +
  '","valueBase64":"kUg0H+Cq/y8HmqnqjvzfBe0z4/IlGgloTOAs0P+y3AgU/Mm1Dj338FhORRnXx83M' +
  'wme0bU9KQfHqF6q7rcVbAw=="}}';

export default function deviceReceiptSignerTest(): void {
  describe('Device receipt Ed25519 signer', () => {
    it('usesOnlyTheExactUtf8ViewWhenTheBufferHasAByteOffset', 0, () => {
      const bytes = deviceReceiptPayloadBytes(PAYLOAD);
      expect(bytes.length).assertEqual(56);
      expect(bytes[0]).assertEqual(123);
      expect(bytes[bytes.length - 1]).assertEqual(125);
    });

    it('roundTripsWhenCryptoKitSupportsEd25519AndOtherwiseFailsClosed', 0, async () => {
      const signer = new Ed25519DeviceReceiptSigner(PUBLIC_KEY, PRIVATE_KEY);
      let output: string = '';
      let failure: string = '';
      try {
        output = await signer.sign(PAYLOAD);
      } catch (error) {
        failure = (error as Error).message;
      }
      if (output.length > 0) {
        expect(output).assertEqual(EXPECTED);
      } else {
        expect(failure).assertEqual('HarmonyOS Ed25519 signing is unavailable in this runtime.');
      }
    });
  });
}
