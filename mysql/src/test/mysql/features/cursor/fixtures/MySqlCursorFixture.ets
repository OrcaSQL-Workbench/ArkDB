import { describe, expect, it } from '@ohos/hypium';

import { ArkDbError, ArkDbErrorKind, ConnectionState } from '@arkdb/core';

import {
  MySqlCursorExecutor, MySqlCursorOptions, MySqlExecutionOutcome, MySqlOperationError,
  MySqlCommandKind, MySqlExecutionEvent, MySqlExecutionEventType,
  MySqlExecutionObserver, MySqlParameter, MySqlParameterType, requireMySqlFeatures
} from '../../../../../../Index';

import {
  initializeMySqlExecutionObserverInternal
} from '../../../../../main/ets/mysql/MySqlConnection';

import {
  Capabilities, ColumnType, StatusFlags
} from '../../../../../main/ets/mysql/protocol/Constants';

import {
  PreparedExecutionFixture, columnPayload, cursorFetchEmptyStrings, cursorFetchResult,
  cursorOpenResult, prepareResponse,
  cursorBufferedFallback, errorPayload, flushPrepared, hex, okPayload, preparedFailureOf
} from '../../prepared/fixtures/PreparedExecutionFixture';

export class CursorExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];
  cursorTerminal: (() => void) | null = null;

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
    const cursorTerminal = this.cursorTerminal;
    if (cursorTerminal !== null &&
      event.type === MySqlExecutionEventType.Terminal &&
      event.commandKind === MySqlCommandKind.Cursor) {
      cursorTerminal();
    }
  }
}

export class FinalFetchTerminalTrace {
  readonly closeStarted: boolean;
  readonly cursorDoneAtClose: boolean;
  readonly fetchSucceeded: boolean;
  readonly exactIdentity: boolean;
  readonly closeSettledBeforeFetch: boolean;

  constructor(closeStarted: boolean, cursorDoneAtClose: boolean,
    fetchSucceeded: boolean, exactIdentity: boolean,
    closeSettledBeforeFetch: boolean) {
    this.closeStarted = closeStarted;
    this.cursorDoneAtClose = cursorDoneAtClose;
    this.fetchSucceeded = fetchSucceeded;
    this.exactIdentity = exactIdentity;
    this.closeSettledBeforeFetch = closeSettledBeforeFetch;
  }
}

export async function expectFetchContinuationRetires(
  statusFlags: number): Promise<void> {
  const fixture = new PreparedExecutionFixture();
  await fixture.open();
  const cursors = requireMySqlFeatures(fixture.connection).cursors;
  if (cursors === undefined) throw new Error('Expected cursor support.');
  const fetchResponse = cursorFetchResult([7], statusFlags);
  fetchResponse.push(okPayload());
  fixture.peer.responses.push(
    prepareResponse(7),
    cursorOpenResult('value'),
    fetchResponse,
    [okPayload()]);
  try {
    const cursor = await cursors.open('SELECT continuation', []);
    const failure = await preparedFailureOf(cursor.fetch());
    await preparedFailureOf(cursor.close());
    const ping = await preparedFailureOf(fixture.connection.ping());

    expect(failure instanceof MySqlOperationError).assertTrue();
    if (failure instanceof MySqlOperationError) {
      expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    }
    expect(ping !== null).assertTrue();
    expect(fixture.connection.state).assertEqual(ConnectionState.Error);
    expect(fixture.peer.closeCalls).assertEqual(1);
    expect(fixture.peer.commands().join(',')).assertEqual('22,23,28');
    expect(fixture.peer.responses.length).assertEqual(1);
  } finally {
    await fixture.close();
  }
}

export function expectCursorServerFailure(failure: ArkDbError | null,
  code: number, sqlState: string): void {
  expect(failure instanceof MySqlOperationError).assertTrue();
  if (failure instanceof MySqlOperationError) {
    expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
    expect(failure.nativeCode).assertEqual(code);
    expect(failure.sqlState).assertEqual(sqlState);
    expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
    expect(failure.cleanupErrors.length).assertEqual(0);
  }
}

export function expectInFlightCloseFailure(failure: ArkDbError | null,
  closing: ArkDbError | null): void {
  expect(retainsInFlightCloseFailure(failure, closing)).assertTrue();
}

export function retainsInFlightCloseFailure(failure: ArkDbError | null,
  closing: ArkDbError | null): boolean {
  if (!(closing instanceof MySqlOperationError) ||
    !(failure instanceof MySqlOperationError) ||
    failure.outcome !== MySqlExecutionOutcome.Unknown) return false;
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup === closing) return true;
  }
  return false;
}

export function requireFailureTask(task: Promise<ArkDbError | null> | null,
  message: string): Promise<ArkDbError | null> {
  if (task === null) throw new Error(message);
  return task;
}

export async function finalFetchSettlesBeforeRootClose(): Promise<boolean> {
  const fixture = new PreparedExecutionFixture();
  await fixture.open();
  const cursors = requireMySqlFeatures(fixture.connection).cursors;
  if (cursors === undefined) throw new Error('Expected cursor support.');
  fixture.peer.responses.push(
    prepareResponse(7),
    cursorOpenResult('value'),
    cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
  let sequence = 0;
  let closeSequence = 0;
  let fetchSequence = 0;
  const cursor = await cursors.open('SELECT value', []);
  const fetching = preparedFailureOf(cursor.fetch())
    .then((failure: ArkDbError | null): ArkDbError | null => {
      fetchSequence = ++sequence;
      return failure;
    });
  try {
    const failure = await fetching;
    fixture.peer.closeFailure =
      new Error('Synthetic root close after final FETCH settlement.');
    closeSequence = ++sequence;
    await preparedFailureOf(fixture.connection.close());
    return failure === null && fetchSequence < closeSequence;
  } finally {
    await preparedFailureOf(fixture.close());
    await fetching;
  }
}

export async function finalFetchClosesAtCursorTerminal(): Promise<FinalFetchTerminalTrace> {
  const fixture = new PreparedExecutionFixture();
  const observer = new CursorExecutionObserver();
  initializeMySqlExecutionObserverInternal(
    fixture.connection, observer, (): number => 100);
  await fixture.open();
  observer.events.length = 0;
  const cursors = requireMySqlFeatures(fixture.connection).cursors;
  if (cursors === undefined) throw new Error('Expected cursor support.');
  fixture.peer.responses.push(
    prepareResponse(7),
    cursorOpenResult('value'),
    cursorFetchResult([7], 2 | StatusFlags.LAST_ROW_SENT));
  fixture.peer.closeFailure =
    new Error('Synthetic sole root close failure at cursor terminal.');
  const cursor = await cursors.open('SELECT value', []);
  let sequence = 0;
  let closeSequence = 0;
  let closeSettledSequence = 0;
  let fetchSequence = 0;
  let closeStarted = false;
  let cursorDoneAtClose = false;
  let closing: Promise<ArkDbError | null> | null = null;
  observer.cursorTerminal = (): void => {
    if (closing !== null) return;
    closeStarted = true;
    cursorDoneAtClose = cursor.done;
    closeSequence = ++sequence;
    closing = preparedFailureOf(fixture.connection.close())
      .then((failure: ArkDbError | null): ArkDbError | null => {
        closeSettledSequence = ++sequence;
        return failure;
      });
  };
  const fetching = preparedFailureOf(cursor.fetch())
    .then((failure: ArkDbError | null): ArkDbError | null => {
      fetchSequence = ++sequence;
      return failure;
    });
  try {
    const failure = await fetching;
    const closeFailure = await requireFailureTask(closing,
      'Expected root close from cursor terminal observation.');
    return new FinalFetchTerminalTrace(
      closeStarted && closeSequence > 0,
      cursorDoneAtClose,
      failure === null,
      failure === closeFailure,
      closeSettledSequence > 0 && closeSettledSequence < fetchSequence);
  } finally {
    observer.cursorTerminal = null;
    await preparedFailureOf(fixture.close());
    await fetching;
    if (closing !== null) await closing;
  }
}

export async function flushCursorTurns(turns: number): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}
