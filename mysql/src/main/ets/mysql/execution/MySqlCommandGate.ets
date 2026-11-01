import { ArkDbError } from '@arkdb/core';

export enum MySqlCommandKind {
  Connect = 'connect',
  Query = 'query',
  QueryStream = 'query_stream',
  Ping = 'ping',
  Context = 'context',
  Transaction = 'transaction',
  Prepare = 'prepare',
  StatementClose = 'statement_close',
  Reset = 'reset',
  Close = 'close'
}

export enum MySqlCommandPhase {
  Reserved = 'reserved',
  Preparing = 'preparing',
  Executing = 'executing',
  Streaming = 'streaming',
  Uploading = 'uploading',
  CursorIdle = 'cursor_idle',
  Fetching = 'fetching',
  Resetting = 'resetting',
  Cleaning = 'cleaning',
  Settled = 'settled'
}

export interface MySqlCommandScope {
  readonly serial: number;
  readonly generation: number;
  readonly kind: MySqlCommandKind;
  readonly phase: MySqlCommandPhase;
  readonly deadlineExpired: boolean;
  readonly ownerToken: Object;
}

export interface MySqlCommandLifecycleObserver {
  onStart(scope: MySqlCommandScope): void;
  onTerminal(scope: MySqlCommandScope): void;
}

class CommandOwnerToken {}

class CommandScope implements MySqlCommandScope {
  readonly serial: number;
  readonly generation: number;
  readonly kind: MySqlCommandKind;
  readonly ownerToken: Object = new CommandOwnerToken();
  phase: MySqlCommandPhase = MySqlCommandPhase.Reserved;
  deadlineExpired: boolean = false;
  advanceGeneration: boolean = false;
  started: boolean = false;

  constructor(serial: number, generation: number, kind: MySqlCommandKind) {
    this.serial = serial;
    this.generation = generation;
    this.kind = kind;
  }
}

export class MySqlCommandGate {
  private serial: number = 0;
  private sessionGeneration: number = 0;
  private active: CommandScope | null = null;
  private lifecycleObserver: MySqlCommandLifecycleObserver | null;

  constructor(lifecycleObserver?: MySqlCommandLifecycleObserver) {
    this.lifecycleObserver = lifecycleObserver === undefined ? null : lifecycleObserver;
  }

  get current(): MySqlCommandScope | null {
    return this.active;
  }

  get generation(): number {
    return this.sessionGeneration;
  }

  get hasReserved(): boolean {
    return this.serial > 0;
  }

  advanceGeneration(): void {
    if (this.active !== null) {
      throw ArkDbError.protocol('The current command must settle before changing the session generation.');
    }
    this.sessionGeneration += 1;
  }

  advanceGenerationOnRelease(scope: MySqlCommandScope): void {
    this.assertOwner(scope);
    this.active!.advanceGeneration = true;
  }

  reserve(kind: MySqlCommandKind): MySqlCommandScope {
    if (this.active !== null) {
      throw ArkDbError.protocol('Another command already owns this connection.');
    }
    this.serial += 1;
    const scope = new CommandScope(this.serial, this.sessionGeneration, kind);
    this.active = scope;
    return scope;
  }

  start(scope: MySqlCommandScope): void {
    this.assertOwner(scope);
    if (this.active!.started) {
      throw ArkDbError.protocol('The command scope start was already delivered.');
    }
    this.active!.started = true;
    if (this.lifecycleObserver !== null) this.lifecycleObserver.onStart(scope);
  }

  isOwner(scope: MySqlCommandScope): boolean {
    return this.active === scope && scope.generation === this.sessionGeneration;
  }

  assertOwner(scope: MySqlCommandScope): void {
    if (!this.isOwner(scope)) {
      throw ArkDbError.protocol('The command scope does not own this connection operation.');
    }
  }

  setPhase(scope: MySqlCommandScope, phase: MySqlCommandPhase): void {
    this.assertOwner(scope);
    this.active!.phase = phase;
  }

  expireDeadline(scope: MySqlCommandScope, serial: number): boolean {
    if (!this.isOwner(scope) || scope.serial !== serial) return false;
    this.active!.deadlineExpired = true;
    return true;
  }

  assertDeadlineActive(scope: MySqlCommandScope): void {
    this.assertOwner(scope);
    if (scope.deadlineExpired) {
      throw ArkDbError.timeout('MySQL operation deadline expired.');
    }
  }

  release(scope: MySqlCommandScope): void {
    this.assertOwner(scope);
    if (this.lifecycleObserver !== null && !this.active!.started) {
      throw ArkDbError.protocol('The command scope must start before it can settle.');
    }
    const advanceGeneration = this.active!.advanceGeneration;
    this.active!.phase = MySqlCommandPhase.Settled;
    this.active = null;
    if (advanceGeneration) this.sessionGeneration += 1;
    if (this.lifecycleObserver !== null) this.lifecycleObserver.onTerminal(scope);
  }
}
