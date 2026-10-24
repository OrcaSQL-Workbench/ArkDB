import { ArkDbError } from '../model/ArkDbError';

export enum CancellationOutcome {
  Requested = 'requested',
  NotRunning = 'not_running'
}

export enum ConnectionReuse {
  NotReady = 'not_ready',
  Ready = 'ready',
  AwaitingCompletion = 'awaiting_completion',
  RequiresSynchronization = 'requires_synchronization',
  Closed = 'closed'
}

export class QueryCancellationResult {
  outcome: CancellationOutcome;
  connectionReuse: ConnectionReuse;

  constructor(outcome: CancellationOutcome, connectionReuse: ConnectionReuse) {
    this.outcome = outcome;
    this.connectionReuse = connectionReuse;
  }
}

/** Bound to one connection; cancel only the execution current at call time.
 * Requested is not proof of interruption. Await the original operation as well.
 * A settled request must never interrupt a later execution.
 */
export interface DbExecutionController {
  cancel(): Promise<QueryCancellationResult>;
  isInterruptionError(error: ArkDbError): boolean;
}