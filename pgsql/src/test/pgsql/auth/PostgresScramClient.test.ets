import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresAuthPlatform, strictUtf8Decode, strictUtf8Encode
} from '../../../main/ets/pgsql/auth/PostgresAuthCrypto';
import {
  DefaultPostgresScramPort, PostgresScramClient, PostgresScramClientState,
  PostgresScramPort
} from '../../../main/ets/pgsql/auth/PostgresScramClient';
import {
  PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue,
  PostgresAuthenticationSaslFinal
} from '../../../main/ets/pgsql/protocol/PostgresMessageChannel';

const RFC_NONCE: string = 'rOprNGfwEbeRWgbNEkqO';
const RFC_SERVER_NONCE: string =
  'rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0';
const RFC_SERVER_FIRST: string =
  'r=' + RFC_SERVER_NONCE + ',s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096';
const RFC_CLIENT_FINAL: string =
  'c=biws,r=' + RFC_SERVER_NONCE +
  ',p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=';
const RFC_SERVER_FINAL: string =
  'v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=';

export default function postgresScramClientTest(): void {
  describe('PostgresScramClient', () => {
    it('matchesRfc7677AndSerializesPostgresSaslFrames', 0, async () => {
      const client = new PostgresScramClient('user', 'pencil', new RfcScramPort());
      const initial = await client.start(new PostgresAuthenticationSasl([
        'SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256'
      ]));
      assertInitialFrame(initial, 'SCRAM-SHA-256',
        'n,,n=user,r=' + RFC_NONCE);
      const response = await client.continue(new PostgresAuthenticationSaslContinue(
        strictUtf8Encode(RFC_SERVER_FIRST)));
      assertResponseFrame(response, RFC_CLIENT_FINAL);
      client.finalize(new PostgresAuthenticationSaslFinal(
        strictUtf8Encode(RFC_SERVER_FINAL)));
      expect(client.state).assertEqual(PostgresScramClientState.Finalized);
    });

    it('generatesEighteenRandomBytesAsCanonicalBase64Nonce', 0, async () => {
      const platform = new NoncePlatform();
      const client = new PostgresScramClient(
        'a,b=c', 'secret', new DefaultPostgresScramPort(platform));
      const frame = await client.start(new PostgresAuthenticationSasl([
        'SCRAM-SHA-256'
      ]));
      expect(platform.requestedRandomBytes).assertEqual(18);
      assertInitialFrame(frame, 'SCRAM-SHA-256',
        'n,,n=a=2Cb=3Dc,r=AAECAwQFBgcICQoLDA0ODxAR');
    });

    it('rejectsMechanismListsWithoutExactScramSha256', 0, async () => {
      for (const mechanisms of [
        new Array<string>(),
        ['SCRAM-SHA-256-PLUS'],
        ['OAUTHBEARER', 'GSSAPI'],
        ['scram-sha-256']
      ]) {
        const client = new PostgresScramClient('user', 'secret', new RfcScramPort());
        await assertAsyncFailure((): Promise<Uint8Array> =>
          client.start(new PostgresAuthenticationSasl(mechanisms)),
        ArkDbErrorKind.Unsupported);
        expect(client.state).assertEqual(PostgresScramClientState.Failed);
      }
    });

    it('rejectsServerFirstSyntaxNonceSaltIterationAndMessageBounds', 0, async () => {
      const oversizedSalt = 'AAAA'.repeat(341) + 'AAA=';
      const invalidMessages: string[] = [
        'r=clientnonceserver,r=duplicate,s=c2FsdA==,i=4096',
        'm=required,r=clientnonceserver,s=c2FsdA==,i=4096',
        's=c2FsdA==,r=clientnonceserver,i=4096',
        'r=,s=c2FsdA==,i=4096',
        'r=othernonce,s=c2FsdA==,i=4096',
        'r=clientnonce,s=c2FsdA==,i=4096',
        'r=clientnonce server,s=c2FsdA==,i=4096',
        'r=clientnonceserver,s=,i=4096',
        'r=clientnonceserver,s=' + oversizedSalt + ',i=4096',
        'r=clientnonceserver,s=abc,i=4096',
        'r=clientnonceserver,s=c2FsdA==,i=0',
        'r=clientnonceserver,s=c2FsdA==,i=01',
        'r=clientnonceserver,s=c2FsdA==,i=+1',
        'r=clientnonceserver,s=c2FsdA==,i=100001',
        'r=clientnonce' + 'a'.repeat(8192) + ',s=c2FsdA==,i=4096'
      ];
      for (const message of invalidMessages) {
        const client = await startedClient(new ZeroScramPort());
        await assertAsyncFailure((): Promise<Uint8Array> => client.continue(
          new PostgresAuthenticationSaslContinue(strictUtf8Encode(message))),
        ArkDbErrorKind.Auth);
        expect(client.state).assertEqual(PostgresScramClientState.Failed);
      }
    });

    it('acceptsOptionalExtensionsInTheirRfcPositions', 0, async () => {
      const client = await startedClient(new ZeroScramPort('a'.repeat(255)));
      await client.continue(new PostgresAuthenticationSaslContinue(strictUtf8Encode(
        'r=' + 'a'.repeat(255) + 'b,s=c2FsdA==,i=4096,x=optional')));
      client.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,x=optional')));
      expect(client.state).assertEqual(PostgresScramClientState.Finalized);
    });

    it('rejectsServerErrorsBadSignaturesAndMalformedFinalAttributes', 0, async () => {
      for (const message of [
        'e=invalid-proof',
        'm=required',
        'v=',
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,v=duplicate',
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,x=a,x=b',
        'v=//////////////////////////////////////////8=',
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' + 'a'.repeat(8192)
      ]) {
        const client = await continuedClient(new ZeroScramPort());
        assertSyncFailure((): void => {
          client.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(message)));
        }, ArkDbErrorKind.Auth);
        expect(client.state).assertEqual(PostgresScramClientState.Failed);
      }
    });

    it('enforcesOneShotOrderingAndTerminalFailure', 0, async () => {
      const fresh = new PostgresScramClient('user', 'secret', new ZeroScramPort());
      await assertAsyncFailure((): Promise<Uint8Array> => fresh.continue(
        new PostgresAuthenticationSaslContinue(strictUtf8Encode(validServerFirst()))),
      ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        fresh.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(
          'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')));
      }, ArkDbErrorKind.Validation);

      const started = await startedClient(new ZeroScramPort());
      await assertAsyncFailure((): Promise<Uint8Array> => started.start(
        new PostgresAuthenticationSasl(['SCRAM-SHA-256'])),
      ArkDbErrorKind.Validation);
      await started.continue(new PostgresAuthenticationSaslContinue(
        strictUtf8Encode(validServerFirst())));
      await assertAsyncFailure((): Promise<Uint8Array> => started.continue(
        new PostgresAuthenticationSaslContinue(strictUtf8Encode(validServerFirst()))),
      ArkDbErrorKind.Validation);
      started.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')));
      assertSyncFailure((): void => {
        started.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(
          'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')));
      }, ArkDbErrorKind.Validation);

      const failed = new PostgresScramClient('user', 'secret', new ZeroScramPort());
      await assertAsyncFailure((): Promise<Uint8Array> => failed.start(
        new PostgresAuthenticationSasl(['SCRAM-SHA-256-PLUS'])),
      ArkDbErrorKind.Unsupported);
      await assertAsyncFailure((): Promise<Uint8Array> => failed.start(
        new PostgresAuthenticationSasl(['SCRAM-SHA-256'])),
      ArkDbErrorKind.Validation);
    });

    it('rejectsOverlappingAsyncTransitions', 0, async () => {
      const port = new DeferredScramPort();
      const client = new PostgresScramClient('user', 'secret', port);
      const firstStart = client.start(new PostgresAuthenticationSasl(['SCRAM-SHA-256']));
      const secondStart = assertAsyncFailure((): Promise<Uint8Array> =>
        client.start(new PostgresAuthenticationSasl(['SCRAM-SHA-256'])),
      ArkDbErrorKind.Validation);
      port.openStart();
      await firstStart;
      await secondStart;
      const firstContinue = client.continue(new PostgresAuthenticationSaslContinue(
        strictUtf8Encode(validServerFirst())));
      const secondContinue = assertAsyncFailure((): Promise<Uint8Array> =>
        client.continue(new PostgresAuthenticationSaslContinue(
          strictUtf8Encode(validServerFirst()))), ArkDbErrorKind.Validation);
      port.openContinue();
      await firstContinue;
      await secondContinue;
    });

    it('snapshotsChallengeAndExpectedServerSignatureBytes', 0, async () => {
      const port = new ZeroScramPort();
      const challenge = strictUtf8Encode(validServerFirst());
      port.onDerive = (): void => { challenge.fill(0); };
      const client = await startedClient(port);
      await client.continue(new PostgresAuthenticationSaslContinue(challenge));
      port.serverSignature.fill(0xff);
      client.finalize(new PostgresAuthenticationSaslFinal(strictUtf8Encode(
        'v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')));
      expect(client.state).assertEqual(PostgresScramClientState.Finalized);
    });

    it('rejectsInvalidClientInputsAndInjectedNonces', 0, async () => {
      for (const username of ['', 'a'.repeat(1025), 'a\u0000b']) {
        const client = new PostgresScramClient(username, 'secret', new ZeroScramPort());
        await assertAsyncFailure((): Promise<Uint8Array> => client.start(
          new PostgresAuthenticationSasl(['SCRAM-SHA-256'])),
        ArkDbErrorKind.Validation);
      }
      for (const nonce of ['', 'bad,nonce', 'bad\nnonce', 'a'.repeat(256)]) {
        const client = new PostgresScramClient(
          'user', 'secret', new ZeroScramPort(nonce));
        await assertAsyncFailure((): Promise<Uint8Array> => client.start(
          new PostgresAuthenticationSasl(['SCRAM-SHA-256'])),
        ArkDbErrorKind.Auth);
      }
      const passwordClient = new PostgresScramClient(
        'user', 'a'.repeat(4097), new ZeroScramPort());
      await passwordClient.start(new PostgresAuthenticationSasl(['SCRAM-SHA-256']));
      await assertAsyncFailure((): Promise<Uint8Array> => passwordClient.continue(
        new PostgresAuthenticationSaslContinue(strictUtf8Encode(validServerFirst()))),
      ArkDbErrorKind.Validation);
    });
  });
}

class RfcScramPort implements PostgresScramPort {
  async createNonce(): Promise<string> { return RFC_NONCE; }
  preparePassword(value: string): Uint8Array {
    expect(value).assertEqual('pencil');
    return strictUtf8Encode(value);
  }
  async deriveSaltedPassword(password: Uint8Array, salt: Uint8Array,
    iterations: number): Promise<Uint8Array> {
    assertText(password, 'pencil');
    assertHex(salt, '5b6d99689d12358eeca04b141236fa81');
    expect(iterations).assertEqual(4096);
    return hexBytes('c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d');
  }
  async sha256(data: Uint8Array): Promise<Uint8Array> {
    assertHex(data, 'a60fc923d67e8644a92d16b96eda5ef4656b0c725c484374be25535576996e8b');
    return hexBytes('586e5df283e6dceb5c3e791d8b8528ec191e664045ce971792e2e6b5bb13e2a6');
  }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const keyHex = bytesHex(key);
    if (keyHex === 'c4a49510323ab4f952cac1fa99441939e78ea74d6be81ddf7096e87513dc615d') {
      const label = strictUtf8Decode(data);
      if (label === 'Client Key') {
        return hexBytes('a60fc923d67e8644a92d16b96eda5ef4656b0c725c484374be25535576996e8b');
      }
      expect(label).assertEqual('Server Key');
      return hexBytes('c1f3cbc1c13a9d35a14c0990eed97629ea225863e566a4314ab99f3f00e5d9d5');
    }
    const authMessage = 'n=user,r=' + RFC_NONCE + ',' + RFC_SERVER_FIRST +
      ',c=biws,r=' + RFC_SERVER_NONCE;
    assertText(data, authMessage);
    if (keyHex === '586e5df283e6dceb5c3e791d8b8528ec191e664045ce971792e2e6b5bb13e2a6') {
      return hexBytes('d27312467c28a40a8a7f05c73c0de33eb3cbfb4a83783b58144cf19ac6be1bdf');
    }
    assertHex(key, 'c1f3cbc1c13a9d35a14c0990eed97629ea225863e566a4314ab99f3f00e5d9d5');
    return hexBytes('eabae24d1062db75a9451ff0b6ea7e98c8546549ff741e672d3251b2397de46e');
  }
}

class NoncePlatform implements PostgresAuthPlatform {
  requestedRandomBytes: number = 0;
  async randomBytes(length: number): Promise<Uint8Array> {
    this.requestedRandomBytes = length;
    const result = new Uint8Array(length);
    for (let index = 0; index < result.length; index += 1) result[index] = index;
    return result;
  }
  async sha256(_data: Uint8Array): Promise<Uint8Array> { throw new Error('not used'); }
  async hmacSha256(_key: Uint8Array, _data: Uint8Array): Promise<Uint8Array> {
    throw new Error('not used');
  }
  normalizeNfkc(value: string): string {
    return value;
  }
}

class ZeroScramPort implements PostgresScramPort {
  private readonly nonce: string;
  private hmacCalls: number = 0;
  onDerive: (() => void) | null = null;
  serverSignature: Uint8Array = new Uint8Array(32);

  constructor(nonce: string = 'clientnonce') {
    this.nonce = nonce;
  }
  async createNonce(): Promise<string> { return this.nonce; }
  preparePassword(value: string): Uint8Array { return strictUtf8Encode(value); }
  async deriveSaltedPassword(_password: Uint8Array, _salt: Uint8Array,
    _iterations: number): Promise<Uint8Array> {
    if (this.onDerive !== null) this.onDerive();
    return new Uint8Array(32);
  }
  async sha256(_data: Uint8Array): Promise<Uint8Array> { return new Uint8Array(32); }
  async hmacSha256(_key: Uint8Array, _data: Uint8Array): Promise<Uint8Array> {
    this.hmacCalls += 1; return this.hmacCalls === 4 ?
      this.serverSignature : new Uint8Array(32);
  }
}

class DeferredScramPort extends ZeroScramPort {
  private readonly startGate: Gate = new Gate();
  private readonly continueGate: Gate = new Gate();
  async createNonce(): Promise<string> {
    await this.startGate.wait(); return super.createNonce();
  }
  async deriveSaltedPassword(password: Uint8Array, salt: Uint8Array,
    iterations: number): Promise<Uint8Array> {
    await this.continueGate.wait();
    return super.deriveSaltedPassword(password, salt, iterations);
  }
  openStart(): void { this.startGate.open(); }
  openContinue(): void { this.continueGate.open(); }
}
class Gate {
  private waiters: Array<() => void> = [];
  wait(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => { this.waiters.push(resolve); });
  }
  open(): void {
    for (const resolve of this.waiters) resolve();
    this.waiters = [];
  }
}

async function startedClient(port: PostgresScramPort): Promise<PostgresScramClient> {
  const client = new PostgresScramClient('user', 'secret', port);
  await client.start(new PostgresAuthenticationSasl(['SCRAM-SHA-256']));
  return client;
}
async function continuedClient(port: PostgresScramPort): Promise<PostgresScramClient> {
  const client = await startedClient(port);
  await client.continue(new PostgresAuthenticationSaslContinue(
    strictUtf8Encode(validServerFirst())));
  return client;
}
function validServerFirst(): string { return 'r=clientnonceserver,s=c2FsdA==,i=4096'; }

function assertInitialFrame(frame: Uint8Array, mechanism: string, response: string): void {
  expect(frame[0]).assertEqual(0x70);
  let end = 5;
  while (frame[end] !== 0) end += 1;
  assertText(frame.subarray(5, end), mechanism);
  const responseLength = new DataView(
    frame.buffer, frame.byteOffset + end + 1, 4).getInt32(0, false);
  expect(responseLength).assertEqual(frame.length - end - 5);
  assertText(frame.subarray(end + 5), response);
}
function assertResponseFrame(frame: Uint8Array, response: string): void {
  expect(frame[0]).assertEqual(0x70);
  expect(new DataView(frame.buffer, frame.byteOffset + 1, 4).getUint32(0, false))
    .assertEqual(frame.length - 1);
  assertText(frame.subarray(5), response);
}
async function assertAsyncFailure(operation: () => Promise<Uint8Array>,
  kind: ArkDbErrorKind): Promise<void> {
  let failure: ArkDbError | null = null;
  try { await operation(); } catch (error) { failure = error as ArkDbError; }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(kind);
}
function assertSyncFailure(operation: () => void, kind: ArkDbErrorKind): void {
  let failure: ArkDbError | null = null;
  try { operation(); } catch (error) { failure = error as ArkDbError; }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(kind);
}
function assertText(actual: Uint8Array, expected: string): void {
  expect(strictUtf8Decode(actual)).assertEqual(expected);
}
function assertHex(actual: Uint8Array, expected: string): void {
  expect(bytesHex(actual)).assertEqual(expected);
}
function bytesHex(value: Uint8Array): string {
  let result = '';
  for (let index = 0; index < value.length; index += 1) {
    result += value[index].toString(16).padStart(2, '0');
  }
  return result;
}
function hexBytes(hex: string): Uint8Array {
  const result = new Uint8Array(hex.length / 2);
  for (let index = 0; index < result.length; index += 1) {
    result[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return result;
}
