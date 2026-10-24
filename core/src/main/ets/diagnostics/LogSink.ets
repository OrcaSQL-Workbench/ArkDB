/**
 * Shared logging levels, sinks, and ArkDB subsystem tags.
 */

/** Severity ordering. A message is emitted only when its level >= Logger.level. */
export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3,
  FATAL = 4,
  OFF = 5
}

/** Default ArkDB HiLog domain (0x0000–0xFFFF for third-party apps). */
export const LOG_DOMAIN: number = 0xF0C5;

/** A destination for log records. The Logger fans every gated call to each sink. */
export interface LogSink {
  write(level: LogLevel, tag: string, message: string, timestampMs: number): void;
}

/** Driver-owned tags; host application subsystems configure their own logging. */
export class LogTag {
  static readonly Conn: string = 'ArkDB.Conn';
  static readonly Auth: string = 'ArkDB.Auth';
  static readonly Proto: string = 'ArkDB.Proto';
  static readonly Net: string = 'ArkDB.Net';
  static readonly Query: string = 'ArkDB.Query';
}
