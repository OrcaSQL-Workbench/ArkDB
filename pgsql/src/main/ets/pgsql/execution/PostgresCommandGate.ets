import { ArkDbError } from '@arkdb/core';

export enum PostgresCommandKind {
  Connect = 'connect', Query = 'query', QueryStream = 'query_stream', Ping = 'ping',
  Context = 'context', Transaction = 'transaction', Prepared = 'prepared', Close = 'close'
}
export enum PostgresCommandPhase {
  Reserved = 'reserved', Connecting = 'connecting', Authenticating = 'authenticating',
  Executing = 'executing', Streaming = 'streaming', Draining = 'draining',
  Closing = 'closing', Settled = 'settled'
}
export interface PostgresCommandScope {
  readonly serial: number;
  readonly generation: number;
  readonly kind: PostgresCommandKind;
  readonly phase: PostgresCommandPhase;
  readonly deadlineExpired: boolean;
  readonly ownerToken: Object;
}
export interface PostgresCommandLifecycleObserver {
  onStart(scope: PostgresCommandScope): void;
  onTerminal(scope: PostgresCommandScope): void;
}
class CommandScope implements PostgresCommandScope {
  readonly serial: number;
  readonly generation: number;
  readonly kind: PostgresCommandKind;
  readonly ownerToken: Object = new Object();
  phase: PostgresCommandPhase = PostgresCommandPhase.Reserved;
  deadlineExpired: boolean = false;
  advanceGeneration: boolean = false;
  started: boolean = false;
  constructor(serial: number, generation: number, kind: PostgresCommandKind) {
    this.serial = serial; this.generation = generation; this.kind = kind;
  }
}
export class PostgresCommandGate {
  private serial: number = 0;
  private sessionGeneration: number = 0;
  private active: CommandScope | null = null;
  private readonly lifecycleObserver: PostgresCommandLifecycleObserver | null;
  constructor(lifecycleObserver?: PostgresCommandLifecycleObserver) {
    this.lifecycleObserver = lifecycleObserver === undefined ? null : lifecycleObserver;
  }
  get current(): PostgresCommandScope | null { return this.active; }
  get generation(): number { return this.sessionGeneration; }
  get hasReserved(): boolean { return this.serial > 0; }
  advanceGeneration(): void {
    if (this.active !== null) {
      throw ArkDbError.protocol(
        'The current command must settle before changing the PostgreSQL session generation.');
    }
    this.sessionGeneration += 1;
  }
  advanceGenerationOnRelease(scope: PostgresCommandScope): void {
    this.assertOwner(scope);
    this.active!.advanceGeneration = true;
  }
  reserve(kind: PostgresCommandKind): PostgresCommandScope {
    if (this.active !== null) {
      throw ArkDbError.protocol('Another command already owns this PostgreSQL connection.');
    }
    this.serial += 1;
    const scope = new CommandScope(this.serial, this.sessionGeneration, kind);
    this.active = scope;
    return scope;
  }
  start(scope: PostgresCommandScope): void {
    this.assertOwner(scope);
    if (this.active!.started) {
      throw ArkDbError.protocol('The PostgreSQL command scope start was already delivered.');
    }
    this.active!.started = true;
    if (this.lifecycleObserver !== null) this.lifecycleObserver.onStart(scope);
  }
  isOwner(scope: PostgresCommandScope): boolean {
    return this.active !== null && this.active === scope &&
      this.active.ownerToken === scope.ownerToken && scope.generation === this.sessionGeneration;
  }
  assertOwner(scope: PostgresCommandScope): void {
    if (!this.isOwner(scope)) {
      throw ArkDbError.protocol('The command scope does not own this PostgreSQL connection operation.');
    }
  }
  setPhase(scope: PostgresCommandScope, phase: PostgresCommandPhase): void {
    this.assertOwner(scope);
    if (phase === PostgresCommandPhase.Settled) {
      throw ArkDbError.protocol('PostgreSQL command scopes can settle only through release.');
    }
    this.active!.phase = phase;
  }
  expireDeadline(scope: PostgresCommandScope, serial: number): boolean {
    if (!this.isOwner(scope) || scope.serial !== serial) return false;
    this.active!.deadlineExpired = true;
    return true;
  }
  assertDeadlineActive(scope: PostgresCommandScope): void {
    this.assertOwner(scope);
    if (scope.deadlineExpired) throw ArkDbError.timeout('PostgreSQL operation deadline expired.');
  }
  release(scope: PostgresCommandScope): void {
    this.assertOwner(scope);
    const current = this.active!;
    if (this.lifecycleObserver !== null && !current.started) {
      throw ArkDbError.protocol('The PostgreSQL command scope must start before it can settle.');
    }
    const advance = current.advanceGeneration;
    current.phase = PostgresCommandPhase.Settled;
    this.active = null;
    if (advance) this.sessionGeneration += 1;
    if (this.lifecycleObserver !== null) this.lifecycleObserver.onTerminal(current);
  }
}
