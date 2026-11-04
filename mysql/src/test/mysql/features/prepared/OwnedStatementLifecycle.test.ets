import { ArkDbError, ArkDbErrorKind, ConnectionState } from '@arkdb/core';
import { describe, expect, it } from '@ohos/hypium';
import { MySqlPreparedStatement } from
  '../../../../main/ets/mysql/api/MySqlPreparedContracts';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../../main/ets/mysql/features/prepared/PreparedStatement';
import {
  OwnedStatementLifecycle
} from '../../../../main/ets/mysql/features/prepared/OwnedStatementLifecycle';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandScope
} from '../../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import { Capabilities } from '../../../../main/ets/mysql/protocol/Constants';
import { PacketChannel } from '../../../../main/ets/mysql/protocol/PacketChannel';
import { PacketTransportFixture } from '../../protocol/PacketTransportFixture';
import {
  framePacket, prepareResponse
} from '../../command/PreparedExecutionFixture';

class OwnedLifecycleTransport extends PacketTransportFixture {
  failWriteAt: number = 0;
  failure: ArkDbError =
    ArkDbError.network('Synthetic owned statement close failure.');

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    await super.write(data, timeoutMs);
    if (this.writes.length === this.failWriteAt) throw this.failure;
  }
}

class OwnedLifecycleHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate = new MySqlCommandGate();
  readonly transport: OwnedLifecycleTransport;
  channel: PacketChannel | null;
  readonly capabilities: number = Capabilities.PROTOCOL_41;
  state: ConnectionState = ConnectionState.Ready;

  constructor(parameterCount: number = 0) {
    const packets = prepareResponse(7, parameterCount);
    const frames: Uint8Array[] = [];
    for (let index = 0; index < packets.length; index += 1) {
      frames.push(framePacket(packets[index], index + 1));
    }
    this.transport = new OwnedLifecycleTransport(frames);
    this.channel = new PacketChannel(this.transport);
  }

  async retire(_error: ArkDbError): Promise<void> {
    this.state = ConnectionState.Closed;
    this.channel = null;
  }
}

class OwnedLifecycleObservation {
  statement: MySqlPreparedStatement | null = null;
  error: ArkDbError | null = null;
}

export default function ownedStatementLifecycleTest(): void {
  describe('MySQL owned prepared statement lifecycle', () => {
    it('preparesOperatesAndClosesWithinTheCallerScope', 0, async () => {
      const host = new OwnedLifecycleHost();
      const observed = new OwnedLifecycleObservation();

      const value = await runOwned(host, async (
        statement: MySqlPreparedStatement): Promise<number> => {
        observed.statement = statement;
        return 42;
      });

      expect(value).assertEqual(42);
      expect(requireStatement(observed.statement).closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.writes[0][4]).assertEqual(0x16);
      expect(host.transport.writes[1][4]).assertEqual(0x19);
    });

    it('preservesAnOrdinaryPrimaryFailureAndStillCloses', 0, async () => {
      const host = new OwnedLifecycleHost();
      const primary = new Error('Synthetic owned operation failure.');

      const failure = await captureFailure(runOwned(host, async (
        _statement: MySqlPreparedStatement): Promise<void> => {
        throw primary;
      }));

      expect(failure.originalCause === primary).assertTrue();
      expect(failure.cleanupErrors.length).assertEqual(0);
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('reportsCloseOnlyFailureAsCompleted', 0, async () => {
      const host = new OwnedLifecycleHost();
      host.transport.failWriteAt = 2;

      const failure = await captureFailure(runOwned(host, async (
        _statement: MySqlPreparedStatement): Promise<void> => {}));

      expect(failure.primary === host.transport.failure).assertTrue();
      expect(failure.cleanupErrors.length).assertEqual(0);
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('preservesPrimaryAndCloseCleanupInOrder', 0, async () => {
      const host = new OwnedLifecycleHost();
      const primary = ArkDbError.validation(
        'Synthetic owned validation failure.');
      host.transport.failWriteAt = 2;

      const failure = await captureFailure(runOwned(host, async (
        _statement: MySqlPreparedStatement): Promise<void> => {
        throw primary;
      }));

      expect(failure.primary === primary).assertTrue();
      expect(failure.cleanupErrors.length).assertEqual(1);
      const cleanup = failure.cleanupErrors[0];
      expect(cleanup instanceof MySqlOperationError).assertTrue();
      if (!(cleanup instanceof MySqlOperationError)) {
        throw new Error('Expected the prepared close cleanup failure.');
      }
      expect(cleanup.primary === host.transport.failure).assertTrue();
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
    });

    it('closesAfterOperationRejectsPreparedCountMismatch', 0, async () => {
      const host = new OwnedLifecycleHost(2);

      const failure = await captureFailure(runOwned(host, async (
        statement: MySqlPreparedStatement): Promise<void> => {
        if (statement.parameterCount !== 1) {
          throw ArkDbError.validation(
            'Parameter count must match the prepared statement');
        }
      }));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.message).assertEqual(
        'Parameter count must match the prepared statement');
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('recoversFromReentrantHandleCloseBeforeStructuralCleanup', 0, async () => {
      const host = new OwnedLifecycleHost();
      const observed = new OwnedLifecycleObservation();

      const value = await runOwned(host, async (
        statement: MySqlPreparedStatement): Promise<number> => {
        try {
          await statement.close();
        } catch (error) {
          if (!(error instanceof ArkDbError)) throw error as Error;
          observed.error = error;
        }
        return 7;
      });

      expect(value).assertEqual(7);
      const reentrantError = requireArkDbError(observed.error);
      expect(reentrantError.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.commandGate.current === null).assertTrue();
    });
  });
}

async function runOwned<T>(host: OwnedLifecycleHost,
  operation: (statement: MySqlPreparedStatement) => Promise<T>): Promise<T> {
  const session = new MySqlPreparedSession(host);
  const lifecycle = new OwnedStatementLifecycle(session);
  const scope: MySqlCommandScope =
    host.commandGate.reserve(MySqlCommandKind.Query);
  try {
    return await lifecycle.withOwnedStatement(scope, 'DO ?', operation);
  } finally {
    if (host.commandGate.current === scope) {
      host.commandGate.release(scope);
    }
  }
}

async function captureFailure<T>(
  task: Promise<T>): Promise<MySqlOperationError> {
  try {
    await task;
  } catch (error) {
    if (error instanceof MySqlOperationError) return error;
    throw error as Error;
  }
  throw new Error('Expected an owned statement lifecycle failure.');
}

function requireStatement(
  statement: MySqlPreparedStatement | null): MySqlPreparedStatement {
  if (statement === null) throw new Error('Expected the owned statement.');
  return statement;
}

function requireArkDbError(error: ArkDbError | null): ArkDbError {
  if (error === null) throw new Error('Expected an ArkDbError.');
  return error;
}
