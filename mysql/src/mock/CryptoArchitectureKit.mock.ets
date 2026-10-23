/**
 * Local Hypium replaces platform CryptoKit calls. This fixture supplies only the independently
 * pinned digest stages and distinct 256-byte RSA outputs used by authentication unit tests.
 */
export namespace cryptoFramework {
  export enum CryptoMode {
    ENCRYPT_MODE = 0
  }

  export class DataBlob {
    data: Uint8Array;

    constructor(data: Uint8Array) {
      this.data = data;
    }
  }

  export interface InputBlob {
    data: Uint8Array;
  }

  export class MockMd {
    private algorithm: string;
    private input: number[] = [];

    constructor(algorithm: string) {
      this.algorithm = algorithm;
    }

    async update(blob: InputBlob): Promise<void> {
      for (let index = 0; index < blob.data.length; index += 1) {
        this.input.push(blob.data[index]);
      }
    }

    async digest(): Promise<DataBlob> {
      return new DataBlob(hexBytes(digestHex(this.algorithm, bytesHex(this.input))));
    }
  }

  export class MockPublicKey {
  }

  export class MockKeyPair {
    pubKey: MockPublicKey = new MockPublicKey();
  }

  export class MockAsyKeyGenerator {
    async convertPemKey(publicKey: string | null, privateKey: string | null): Promise<MockKeyPair> {
      if (publicKey === null ||
        !publicKey.startsWith('-----BEGIN PUBLIC KEY-----\n') ||
        !publicKey.endsWith('-----END PUBLIC KEY-----\n') ||
        privateKey !== null) {
        throw new Error('Malformed RSA public key fixture');
      }
      return new MockKeyPair();
    }
  }

  export class MockCipher {
    private initialized: boolean = false;

    async init(mode: CryptoMode, publicKey: MockPublicKey, parameters: Object | null): Promise<void> {
      if (mode !== CryptoMode.ENCRYPT_MODE || parameters !== null) {
        throw new Error('Unsupported RSA fixture initialization');
      }
      this.initialized = publicKey !== null;
    }

    async doFinal(blob: InputBlob): Promise<DataBlob> {
      if (!this.initialized) throw new Error('RSA fixture cipher is not initialized');
      cipherInvocation += 1;
      const output = new Uint8Array(256);
      for (let index = 0; index < output.length; index += 1) {
        const input = blob.data.length > 0 ? blob.data[index % blob.data.length] : 0;
        output[index] = (input + index + cipherInvocation * 17) & 0xff;
      }
      return new DataBlob(output);
    }
  }

  let cipherInvocation: number = 0;

  export function createMd(algorithm: string): MockMd {
    if (algorithm !== 'SHA1' && algorithm !== 'SHA256') {
      throw new Error('Unsupported digest fixture algorithm: ' + algorithm);
    }
    return new MockMd(algorithm);
  }

  export function createAsyKeyGenerator(algorithm: string): MockAsyKeyGenerator {
    if (algorithm !== 'RSA2048') {
      throw new Error('Unsupported key fixture algorithm: ' + algorithm);
    }
    return new MockAsyKeyGenerator();
  }

  export function createCipher(transformation: string): MockCipher {
    if (transformation !== 'RSA2048|PKCS1_OAEP|SHA1|MGF1_SHA1') {
      throw new Error('Unsupported cipher fixture transformation: ' + transformation);
    }
    return new MockCipher();
  }
}

function digestHex(algorithm: string, input: string): string {
  if (algorithm === 'SHA1') {
    if (input === '70617373776f7264') {
      return '5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8';
    }
    if (input === '5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8') {
      return '2470c0c06dee42fd1618bb99005adca2ec9d1e19';
    }
    if (input ===
      '00112233445566778899aabbccddeeff102132432470c0c06dee42fd1618bb99005adca2ec9d1e19') {
      return '08d59284f6002762b9ebc6b164dde0fa263a5828';
    }
    if (input === 'e5af86e7a081f09f9492') {
      return 'ecbdd1da4c3db1a1ba49c5092bcfccb7ac69abdd';
    }
    if (input === 'ecbdd1da4c3db1a1ba49c5092bcfccb7ac69abdd') {
      return 'cc2384526fc149999264f063c3cc5776b0833842';
    }
    if (input ===
      '00112233445566778899aabbccddeeff10213243cc2384526fc149999264f063c3cc5776b0833842') {
      return 'd3e4d66856a03e8617ece84e024d61428e32ba20';
    }
  } else if (algorithm === 'SHA256') {
    if (input === '70617373776f7264') {
      return '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8';
    }
    if (input === '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8') {
      return '73641c99f7719f57d8f4beb11a303afcd190243a51ced8782ca6d3dbe014d146';
    }
    if (input ===
      '73641c99f7719f57d8f4beb11a303afcd190243a51ced8782ca6d3dbe014d146' +
      '00112233445566778899aabbccddeeff10213243') {
      return '4661874b1fb3f553e751624d477c3934574917fcd3a11a4b1a875026ec90326e';
    }
    if (input === 'e5af86e7a081f09f9492') {
      return '39fe364ba5d03d9063aa4e81be62283ad6ebd77e0a2428575897ab3d4ebdf12b';
    }
    if (input === '39fe364ba5d03d9063aa4e81be62283ad6ebd77e0a2428575897ab3d4ebdf12b') {
      return '5504ed06b980515942ee1fc89296381f099aa989b0cc6941dfd1f8953efc59b8';
    }
    if (input ===
      '5504ed06b980515942ee1fc89296381f099aa989b0cc6941dfd1f8953efc59b8' +
      '00112233445566778899aabbccddeeff10213243') {
      return '0628f76106f6dde0fe78c2b18477ed3602fab6fa33cf1c91252fd8a0a6e7cdf7';
    }
  }
  throw new Error('Unexpected ' + algorithm + ' digest fixture input');
}

function bytesHex(bytes: number[]): string {
  let hex = '';
  for (let index = 0; index < bytes.length; index += 1) {
    hex += byteHex(bytes[index]);
  }
  return hex;
}

function byteHex(value: number): string {
  const hex = value.toString(16);
  return hex.length === 1 ? '0' + hex : hex;
}

function hexBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

export default cryptoFramework;
