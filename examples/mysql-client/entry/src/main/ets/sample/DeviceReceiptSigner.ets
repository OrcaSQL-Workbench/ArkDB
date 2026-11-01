import { buffer, util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

class DeviceReceiptSignature {
  algorithm: string = 'Ed25519';
  publicKeySpkiBase64: string = '';
  valueBase64: string = '';
}

class DeviceReceiptEnvelope {
  schemaVersion: number = 1;
  kind: string = 'arkdb-device-acceptance-envelope';
  payload: string = '';
  signature: DeviceReceiptSignature = new DeviceReceiptSignature();
}

export interface DeviceReceiptSigner {
  sign(payload: string): Promise<string>;
}

export class Ed25519DeviceReceiptSigner implements DeviceReceiptSigner {
  private publicKeySpkiBase64: string;
  private privateKeyPkcs8Base64: string;

  constructor(publicKeySpkiBase64: string, privateKeyPkcs8Base64: string) {
    this.publicKeySpkiBase64 = publicKeySpkiBase64;
    this.privateKeyPkcs8Base64 = privateKeyPkcs8Base64;
  }

  async sign(payload: string): Promise<string> {
    try {
      const base64 = new util.Base64Helper();
      const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const pair = generator.convertKeySync(
        { data: base64.decodeSync(this.publicKeySpkiBase64) },
        { data: base64.decodeSync(this.privateKeyPkcs8Base64) }
      );
      const signer = cryptoFramework.createSign('Ed25519');
      signer.initSync(pair.priKey);
      const signature = signer.signSync({
        data: deviceReceiptPayloadBytes(payload)
      });
      if (signature.data.length !== 64) {
        throw new Error('Invalid Ed25519 signature length.');
      }
      const envelope = new DeviceReceiptEnvelope();
      envelope.payload = payload;
      envelope.signature.publicKeySpkiBase64 = this.publicKeySpkiBase64;
      envelope.signature.valueBase64 = encodeBase64(signature.data);
      return JSON.stringify(envelope);
    } catch (error) {
      throw new Error('HarmonyOS Ed25519 signing is unavailable in this runtime.');
    }
  }
}

export function deviceReceiptPayloadBytes(payload: string): Uint8Array {
  const bytes = buffer.from(payload, 'utf-8');
  return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.length);
}

function encodeBase64(bytes: Uint8Array): string {
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let output: string = '';
  for (let index = 0; index < bytes.length; index += 3) {
    const first = bytes[index];
    const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
    const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
    output += alphabet.charAt(first >> 2);
    output += alphabet.charAt(((first & 0x03) << 4) | (second >> 4));
    output += index + 1 < bytes.length ?
      alphabet.charAt(((second & 0x0f) << 2) | (third >> 6)) : '=';
    output += index + 2 < bytes.length ? alphabet.charAt(third & 0x3f) : '=';
  }
  return output;
}
