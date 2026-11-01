import { Logger, LogTag, monotonicNowMs } from '@arkdb/core';
import {
  MySqlCommandKind, MySqlCommandLifecycleObserver, MySqlCommandScope
} from '../execution/MySqlCommandGate';

export enum MySqlExecutionEventType {
  Start = 'start',
  Terminal = 'terminal'
}

export class MySqlExecutionEvent {
  readonly type: MySqlExecutionEventType;
  readonly serial: number;
  readonly generation: number;
  readonly commandKind: MySqlCommandKind;
  readonly monotonicTimeMs: number;
  readonly durationMs: number;

  constructor(type: MySqlExecutionEventType, serial: number, generation: number,
    commandKind: MySqlCommandKind, monotonicTimeMs: number, durationMs: number) {
    this.type = type;
    this.serial = serial;
    this.generation = generation;
    this.commandKind = commandKind;
    this.monotonicTimeMs = monotonicTimeMs;
    this.durationMs = durationMs;
  }
}

export interface MySqlExecutionObserver {
  onEvent(event: MySqlExecutionEvent): void;
}

export class MySqlExecutionDispatcher implements MySqlCommandLifecycleObserver {
  private observer: MySqlExecutionObserver | null;
  private clock: () => number;
  private startedSerial: number = 0;
  private startedAtMs: number = 0;

  constructor(observer: MySqlExecutionObserver, clock: () => number = monotonicNowMs) {
    this.observer = observer;
    this.clock = clock;
  }

  onStart(scope: MySqlCommandScope): void {
    const now = this.readTime();
    if (now === null) return;
    this.startedSerial = scope.serial;
    this.startedAtMs = now;
    this.deliver(new MySqlExecutionEvent(MySqlExecutionEventType.Start,
      scope.serial, scope.generation, scope.kind, now, 0));
  }

  onTerminal(scope: MySqlCommandScope): void {
    const now = this.readTime();
    if (now === null) return;
    const duration = this.startedSerial === scope.serial ?
      safeDurationMs(now - this.startedAtMs) : 0;
    this.startedSerial = 0;
    this.startedAtMs = 0;
    this.deliver(new MySqlExecutionEvent(MySqlExecutionEventType.Terminal,
      scope.serial, scope.generation, scope.kind, now, duration));
  }

  private readTime(): number | null {
    if (this.observer === null) return null;
    try {
      return safeTimeMs(this.clock());
    } catch (error) {
      this.removeObserver(error as Object);
      return null;
    }
  }

  private deliver(event: MySqlExecutionEvent): void {
    const observer = this.observer;
    if (observer === null) return;
    try {
      observer.onEvent(event);
    } catch (error) {
      this.removeObserver(error as Object);
    }
  }

  private removeObserver(error: Object): void {
    this.observer = null;
    try {
      Logger.w(LogTag.Query,
        'execution observer removed error=' + Logger.errorToken(error));
    } catch (_loggingError) {
    }
  }
}

function safeTimeMs(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.floor(value));
}

function safeDurationMs(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.floor(value));
}
