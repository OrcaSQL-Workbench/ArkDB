import { describe, expect, it } from '@ohos/hypium';

import { ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions } from '@arkdb/core';

import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../../../main/ets/mysql/features/prepared/PreparedStatement';

import {
  MySqlPreparedStatement
} from '../../../../../main/ets/mysql/api/MySqlPreparedContracts';

import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandLifecycleObserver, MySqlCommandScope
} from '../../../../../main/ets/mysql/execution/MySqlCommandGate';

import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../../main/ets/mysql/model/MySqlOperationError';

import {
  MySqlQueryResultMeta, MySqlQueryResultSink, MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../../../main/ets/mysql/model/MySqlQueryStream';

import { Capabilities } from '../../../../../main/ets/mysql/protocol/Constants';

import { PacketChannel } from '../../../../../main/ets/mysql/protocol/PacketChannel';

import { PacketWriter } from '../../../../../main/ets/mysql/protocol/PacketWriter';

import { PacketTransportFixture } from '../../../protocol/fixtures/PacketTransportFixture';

export class PreparedTransport extends PacketTransportFixture {
  failWriteAt: number = 0;
  failReadAt: number = 0;
  holdWriteAt: number = 0;
  holdReadAt: number = 0;
  readAttempts: number = 0;
  writeFailure: ArkDbError | Error = ArkDbError.network('Synthetic prepared write failure.');
  readFailure: ArkDbError | Error = ArkDbError.network('Synthetic prepared read failure.');
  private resumeWrite: (() => void) | null = null;
  private resumeRead: (() => void) | null = null;

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    await super.write(data, timeoutMs);
    const attempt = this.writes.length;
    if (attempt === this.holdWriteAt) {
      await new Promise<void>((resolve: () => void): void => { this.resumeWrite = resolve; });
    }
    if (attempt === this.failWriteAt) throwFixtureFailure(this.writeFailure);
  }

  async read(length: number, timeoutMs: number = 0): Promise<Uint8Array> {
    this.readAttempts += 1;
    if (this.readAttempts === this.holdReadAt) {
      await new Promise<void>((resolve: () => void): void => { this.resumeRead = resolve; });
    }
    if (this.readAttempts === this.failReadAt) throwFixtureFailure(this.readFailure);
    return super.read(length, timeoutMs);
  }

  releaseWrite(): void {
    const resume = this.resumeWrite;
    this.resumeWrite = null;
    if (resume !== null) resume();
  }

  releaseRead(): void {
    const resume = this.resumeRead;
    this.resumeRead = null;
    if (resume !== null) resume();
  }
}

export class PreparedChannel extends PacketChannel {
  resets: number = 0;

  resetSequence(): void {
    this.resets += 1;
    super.resetSequence();
  }
}

export class ReleaseFailureGate extends MySqlCommandGate {
  closeReleaseFailure: ArkDbError | null = null;
  closeReleaseCalls: number = 0;

  release(scope: MySqlCommandScope): void {
    super.release(scope);
    if (scope.kind === MySqlCommandKind.StatementClose) {
      this.closeReleaseCalls += 1;
      const failure = this.closeReleaseFailure;
      if (failure !== null) throw failure;
    }
  }
}

export class PreparedHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate;
  readonly transport: PreparedTransport;
  readonly initialChannel: PreparedChannel;
  channel: PacketChannel | null;
  capabilities: number;
  state: ConnectionState = ConnectionState.Ready;
  retirements: ArkDbError[] = [];
  retirementFailure: ArkDbError | Error | null = null;
  holdRetirement: boolean = false;
  private resumeRetirement: (() => void) | null = null;

  constructor(responses: Uint8Array[][], capabilities: number = Capabilities.PROTOCOL_41,
    firstSequences: number[] = [], commandGate: MySqlCommandGate = new MySqlCommandGate()) {
    this.commandGate = commandGate;
    const frames: Uint8Array[] = [];
    for (let response = 0; response < responses.length; response += 1) {
      const firstSequence = response < firstSequences.length ? firstSequences[response] : 1;
      for (let index = 0; index < responses[response].length; index += 1) {
        frames.push(frame(responses[response][index], (firstSequence + index) & 0xff));
      }
    }
    this.transport = new PreparedTransport(frames);
    this.initialChannel = new PreparedChannel(this.transport);
    this.channel = this.initialChannel;
    this.capabilities = capabilities;
  }

  async retire(error: ArkDbError): Promise<void> {
    this.retirements.push(error);
    this.state = ConnectionState.Closed;
    this.channel = null;
    if (this.holdRetirement) {
      await new Promise<void>((resolve: () => void): void => { this.resumeRetirement = resolve; });
    }
    const failure = this.retirementFailure;
    if (failure !== null) throwFixtureFailure(failure);
  }

  releaseRetirement(): void {
    const resume = this.resumeRetirement;
    this.resumeRetirement = null;
    if (resume !== null) resume();
  }
}

export class PreparedObservation {
  statement: MySqlPreparedStatement | null = null;
  error: Object | null = null;
}

export enum CloseEntry {
  Handle,
  Session,
  Owned
}

export class CloseObservation {
  settled: boolean = false;
  error: Object | null = null;
  readonly done: Promise<void>;

  constructor(task: Promise<void>) {
    this.done = task.then((): void => {
      this.settled = true;
    }, (error: Object): void => {
      this.error = error;
      this.settled = true;
    });
  }
}

export class RecordingSink implements MySqlQueryResultSink {
  calls: number = 0;

  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> { this.calls += 1; }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { this.calls += 1; }
  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> { this.calls += 1; }
}

export class StatementCloseStartObserver implements MySqlCommandLifecycleObserver {
  statement: MySqlPreparedStatement | null = null;
  repeated: Promise<void> | null = null;
  closeStarts: number = 0;
  closeTerminals: number = 0;

  onStart(scope: MySqlCommandScope): void {
    if (scope.kind !== MySqlCommandKind.StatementClose || this.statement === null) return;
    this.closeStarts += 1;
    if (this.repeated === null) this.repeated = this.statement.close();
  }

  onTerminal(scope: MySqlCommandScope): void {
    if (scope.kind === MySqlCommandKind.StatementClose) this.closeTerminals += 1;
  }
}

export class SessionCloseStartObserver implements MySqlCommandLifecycleObserver {
  session: MySqlPreparedSession | null = null;
  statement: MySqlPreparedStatement | null = null;
  repeated: Promise<void> | null = null;

  onStart(scope: MySqlCommandScope): void {
    if (scope.kind !== MySqlCommandKind.StatementClose ||
      this.session === null || this.statement === null ||
      this.repeated !== null) return;
    this.repeated = this.session.close(this.statement);
  }

  onTerminal(_scope: MySqlCommandScope): void {}
}

export async function expectReuseAtRepeatedSessionClose(entry: CloseEntry): Promise<void> {
  const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
  const session = new MySqlPreparedSession(host);
  const statement = await prepareSuccessfully(session, 'DO 7');
  host.transport.holdWriteAt = 2;
  const original = new CloseObservation(session.close(statement));
  const scope = host.commandGate.current!;
  const repeated = entry === CloseEntry.Handle ? statement.close() :
    (entry === CloseEntry.Session ? session.close(statement) : session.closeOwned(scope, statement));
  await nextTask();
  host.transport.releaseWrite();
  let repeatedFailure: Object | null = null;
  try { await repeated; } catch (error) { repeatedFailure = error as Object; }
  const gateSettledAtContinuation = host.commandGate.current === null;
  const immediatelyReused = await capturePrepared(session.prepare('DO 8'));
  await original.done;
  if (immediatelyReused.statement !== null) await immediatelyReused.statement.close();
  expect(repeatedFailure === null).assertTrue();
  expect(gateSettledAtContinuation).assertTrue();
  expect(immediatelyReused.error === null).assertTrue();
  expect(immediatelyReused.statement !== null).assertTrue();
  expect(original.error === null).assertTrue();
  expect(statement.closed).assertTrue();
  expect(scope.serial).assertEqual(2);
  expect(host.commandGate.current === null).assertTrue();
  expect(host.transport.writes.length).assertEqual(4);
  expect(host.transport.readAttempts).assertEqual(4);
  expect(host.initialChannel.resets).assertEqual(4);
  expect(host.retirements.length).assertEqual(0);
}

export async function expectPendingCloseJoined(entry: CloseEntry): Promise<void> {
  const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
  const session = new MySqlPreparedSession(host);
  const statement = await prepareSuccessfully(session, 'DO 7');
  let callerScope: MySqlCommandScope | null = null;
  if (entry === CloseEntry.Owned) callerScope = host.commandGate.reserve(MySqlCommandKind.Transaction);
  host.transport.holdWriteAt = 2;
  const first = new CloseObservation(entry === CloseEntry.Handle ? statement.close() :
    (entry === CloseEntry.Session ? session.close(statement) : session.closeOwned(callerScope!, statement)));
  await nextTask();
  const scope = host.commandGate.current!;
  const repeated = [
    new CloseObservation(statement.close()),
    new CloseObservation(session.close(statement)),
    new CloseObservation(session.closeOwned(scope, statement))
  ];
  await nextTask();
  const allPending = !first.settled && repeated.every((item: CloseObservation): boolean => !item.settled);
  const unchangedScope = host.commandGate.current === scope;
  const serial = scope.serial;
  const writes = host.transport.writes.length;
  const reads = host.transport.readAttempts;
  const resets = host.initialChannel.resets;
  host.transport.releaseWrite();
  await first.done;
  for (const item of repeated) await item.done;
  const callerScopeRetained = callerScope === null ? host.commandGate.current === null :
    host.commandGate.current === callerScope;
  if (callerScope !== null) {
    await session.closeOwned(callerScope, statement);
    host.commandGate.release(callerScope);
  }
  await statement.close();
  await session.close(statement);
  expect(allPending).assertTrue();
  expect(unchangedScope).assertTrue();
  expect(serial).assertEqual(2);
  expect(first.error === null).assertTrue();
  expect(repeated.every((item: CloseObservation): boolean => item.error === null)).assertTrue();
  expect(callerScopeRetained).assertTrue();
  expect(statement.closed).assertTrue();
  expect(writes).assertEqual(2);
  expect(reads).assertEqual(2);
  expect(resets).assertEqual(2);
  expect(host.transport.writes.length).assertEqual(2);
  expect(host.transport.readAttempts).assertEqual(2);
  expect(host.initialChannel.resets).assertEqual(2);
  expect(host.retirements.length).assertEqual(0);
  expect(host.commandGate.current === null).assertTrue();
}

export async function expectOwnedCloseFailureJoined(ordinary: boolean): Promise<void> {
  const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
  const session = new MySqlPreparedSession(host);
  const statement = await prepareSuccessfully(session, 'DO 7');
  const other = await prepareSuccessfully(session, 'DO 8');
  const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
  const primary: ArkDbError | Error = ordinary ? new Error('Synthetic ordinary owned CLOSE failure.') :
    new ArkDbError(ArkDbErrorKind.Network, 'Synthetic owned CLOSE failure.', 2006, 'HY000');
  const cleanup: ArkDbError | Error = ordinary ? new Error('Synthetic ordinary retirement failure.') :
    ArkDbError.timeout('Synthetic owned CLOSE retirement failure.');
  host.transport.failWriteAt = 3;
  host.transport.writeFailure = primary;
  host.retirementFailure = cleanup;
  host.holdRetirement = true;
  const first = new CloseObservation(session.closeOwned(scope, statement));
  await nextTask();
  const repeated = [
    new CloseObservation(statement.close()),
    new CloseObservation(session.close(statement)),
    new CloseObservation(session.closeOwned(scope, statement))
  ];
  await nextTask();
  const allPendingUntilRetirement = !first.settled &&
    repeated.every((item: CloseObservation): boolean => !item.settled);
  const scopeRetainedDuringRetirement = host.commandGate.current === scope;
  const retirements = host.retirements.length;
  const writes = host.transport.writes.length;
  const reads = host.transport.readAttempts;
  const resets = host.initialChannel.resets;
  host.releaseRetirement();
  await first.done;
  for (const item of repeated) await item.done;
  const afterFailure = [
    new CloseObservation(statement.close()),
    new CloseObservation(session.close(statement)),
    new CloseObservation(session.closeOwned(scope, statement))
  ];
  for (const item of afterFailure) await item.done;
  const scopeRetainedAfterFailure = host.commandGate.current === scope;
  host.commandGate.release(scope);
  expect(allPendingUntilRetirement).assertTrue();
  expect(scopeRetainedDuringRetirement).assertTrue();
  expect(scopeRetainedAfterFailure).assertTrue();
  expect(first.error instanceof MySqlOperationError).assertTrue();
  if (!(first.error instanceof MySqlOperationError)) throw new Error('Missing original close failure.');
  const failure = first.error;
  expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
  expect(failure.cleanupErrors.length).assertEqual(1);
  if (primary instanceof ArkDbError) {
    expect(failure.primary === primary).assertTrue();
    expect(failure.nativeCode).assertEqual(2006);
    expect(failure.code).assertEqual(2006);
    expect(failure.sqlState).assertEqual('HY000');
    expect(failure.cleanupErrors[0] === cleanup).assertTrue();
  } else {
    expect(failure.originalCause === primary).assertTrue();
    expect(asOperation(failure.cleanupErrors[0]).originalCause === cleanup).assertTrue();
  }
  expect(repeated.every((item: CloseObservation): boolean => item.error === failure)).assertTrue();
  expect(afterFailure.every((item: CloseObservation): boolean => item.error === failure)).assertTrue();
  expect(retirements).assertEqual(1);
  expect(writes).assertEqual(3);
  expect(reads).assertEqual(4);
  expect(resets).assertEqual(3);
  expect(statement.closed).assertTrue();
  expect(other.closed).assertTrue();
  expect(host.state).assertEqual(ConnectionState.Closed);
  expect(host.transport.writes.length).assertEqual(3);
  expect(host.transport.readAttempts).assertEqual(4);
  expect(host.initialChannel.resets).assertEqual(3);
  expect(host.retirements.length).assertEqual(1);
  expect(host.commandGate.current === null).assertTrue();
}

export async function expectUnknownMetadataRejected(parameter: boolean): Promise<void> {
  for (let mode = 0; mode < 2; mode += 1) {
    const response = [prepareOk(8, parameter ? 1 : 0, parameter ? 0 : 1), column('unknown', 0x80)];
    if (mode === 0) response.push(eof());
    const host = new PreparedHost([[prepareOk(7, 0, 0)], response],
      Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
    const session = new MySqlPreparedSession(host);
    const existing = await prepareSuccessfully(session, 'DO 7');
    const error = asOperation(await observeFailure(() => session.prepare('SELECT ?')));
    expect(error.kind).assertEqual(ArkDbErrorKind.Unsupported);
    expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    expect(existing.closed).assertTrue();
    expect(host.state).assertEqual(ConnectionState.Closed);
    expect(host.retirements.length).assertEqual(1);
    expect(host.commandGate.current === null).assertTrue();
    await existing.close();
    expect(host.transport.writes.length).assertEqual(2);
  }
}

export async function expectOwnedPrepareOverlapRejected(otherOwner: boolean, closeExisting: boolean): Promise<void> {
  const host = new PreparedHost([
    [prepareOk(7, 0, 0)],
    [prepareOk(8, 0, 1), column('result'), eof()],
    [prepareOk(9, 0, 0)]
  ]);
  const owner = new MySqlPreparedSession(host);
  const other = otherOwner ? new MySqlPreparedSession(host) : owner;
  const existing = await prepareSuccessfully(other, 'DO 7');
  const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
  host.transport.holdReadAt = 5;
  const pending = capturePrepared(owner.prepareOwned(scope, 'SELECT 1'));
  await nextTask();
  const writes = host.transport.writes.length;
  const reads = host.transport.readAttempts;
  const resets = host.initialChannel.resets;
  const phase = scope.phase;
  let overlapError: Object | null = null;
  if (closeExisting) {
    overlapError = await captureCommandFailure(other.closeOwned(scope, existing));
  } else {
    overlapError = (await capturePrepared(other.prepareOwned(scope, 'DO 9'))).error;
  }
  const writesAfter = host.transport.writes.length;
  const readsAfter = host.transport.readAttempts;
  const resetsAfter = host.initialChannel.resets;
  const phaseAfter = scope.phase;
  const existingStillOpen = !existing.closed;
  host.transport.releaseRead();
  const first = await pending;
  const firstStillOpen = first.statement !== null && !first.statement.closed;
  let sequential: PreparedObservation | null = null;
  try {
    if (first.statement !== null && overlapError !== null && host.state === ConnectionState.Ready) {
      owner.assertUsable(scope, first.statement);
      other.assertUsable(scope, existing);
      sequential = await capturePrepared(other.prepareOwned(scope, 'DO 9'));
      await owner.closeOwned(scope, first.statement);
      await other.closeOwned(scope, existing);
      if (sequential.statement !== null) await other.closeOwned(scope, sequential.statement);
    }
  } finally {
    host.commandGate.release(scope);
  }
  expectProtocolError(overlapError);
  expect(writesAfter).assertEqual(writes);
  expect(readsAfter).assertEqual(reads);
  expect(resetsAfter).assertEqual(resets);
  expect(phaseAfter).assertEqual(phase);
  expect(existingStillOpen).assertTrue();
  expect(first.error === null).assertTrue();
  expect(firstStillOpen).assertTrue();
  expect(sequential !== null && sequential.error === null).assertTrue();
  expect(host.retirements.length).assertEqual(0);
  expect(host.commandGate.current === null).assertTrue();
}

export async function capturePrepared(task: Promise<MySqlPreparedStatement>): Promise<PreparedObservation> {
  const outcome = new PreparedObservation();
  try { outcome.statement = await task; } catch (error) { outcome.error = error as Object; }
  return outcome;
}

export async function captureCommandFailure<T>(task: Promise<T>): Promise<Object | null> {
  try { await task; } catch (error) { return error as Object; }
  return null;
}

export function expectProtocolError(error: Object | null): void {
  expect(error instanceof ArkDbError).assertTrue();
  if (error instanceof ArkDbError) expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
}

export async function prepareSuccessfully(session: MySqlPreparedSession, sql: string): Promise<MySqlPreparedStatement> {
  let statement: MySqlPreparedStatement | null = null;
  let failure: Object | null = null;
  try { statement = await session.prepare(sql); } catch (error) { failure = error as Object; }
  expect(failure === null).assertTrue();
  expect(statement !== null).assertTrue();
  return statement!;
}

export function expectProtocol(action: () => void): void {
  let failure: ArkDbError | null = null;
  try { action(); } catch (error) {
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

export async function observeFailure<T>(action: () => Promise<T>): Promise<ArkDbError> {
  let failure: ArkDbError | null = null;
  try { await action(); } catch (error) {
    expect(error instanceof ArkDbError).assertTrue();
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  return failure!;
}

export function asOperation(error: ArkDbError): MySqlOperationError {
  expect(error instanceof MySqlOperationError).assertTrue();
  if (error instanceof MySqlOperationError) return error;
  throw new Error('Expected the canonical MySQL operation error.');
}

export function throwFixtureFailure(error: ArkDbError | Error): never {
  if (error instanceof ArkDbError) throw error;
  throw error;
}

export function nextTask(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
}

export function prepareOk(id: number, parameters: number, columns: number): Uint8Array {
  return new PacketWriter().writeUInt8(0).writeUInt32(id).writeUInt16(columns)
    .writeUInt16(parameters).writeUInt8(0).writeUInt16(0).toUint8Array();
}

export function serverErr(code: number, sqlState: string): Uint8Array {
  return new PacketWriter().writeUInt8(0xff).writeUInt16(code).writeUInt8(0x23)
    .writeString(sqlState).writeString('Synthetic server rejection.').toUint8Array();
}

export function column(name: string, type: number = 0xfd): Uint8Array {
  return new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString(name)
    .writeLenEncString(name).writeUInt8(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(type).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
}

export function eof(): Uint8Array {
  return new Uint8Array([0xfe, 0, 0, 2, 0]);
}

export function frame(payload: Uint8Array, sequence: number): Uint8Array {
  const result = new Uint8Array(payload.length + 4);
  result[0] = payload.length & 0xff;
  result[1] = (payload.length >>> 8) & 0xff;
  result[2] = (payload.length >>> 16) & 0xff;
  result[3] = sequence;
  result.set(payload, 4);
  return result;
}

export function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
