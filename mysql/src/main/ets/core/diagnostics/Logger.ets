/**
 * Driver logger with privacy-aware tokens and configurable sinks.
 *
 * Each call composes one message string (no printf varargs) and is
 * fanned out to a registry of sinks: a HilogSink (always) and, once the app calls
 * `enableFileSink`, an optional rotating FileSink. Levels gate output cheaply.
 *
 * Privacy: never pass secrets (passwords/scrambles/RSA/salt). Wrap sensitive-but-
 * useful identifiers (host/user/schema/SQL) with `mask()`, a short deterministic
 * pseudonymous token. It avoids storing the raw value but is not anonymization.
 *
 * Each JS context has its own configuration. The host opts into any file output
 * and configures sinks separately in each context.
 */
import { LogLevel, LogSink } from './LogSink';
import { HilogSink } from './HilogSink';
import { FileSink } from './FileSink';
import BuildProfile from '../../../../../BuildProfile';

export class Logger {
  /** Gate — messages below this level are dropped before any sink.
   *  Build-aware default: DEBUG in debug builds, INFO in release. Override via setLevel(). */
  static level: LogLevel = BuildProfile.DEBUG ? LogLevel.DEBUG : LogLevel.INFO;

  /** Rotating-file budget (per thread). Override before `enableFileSink`. */
  static fileMaxBytes: number = 1024 * 1024; // 1 MiB
  static fileMaxFiles: number = 5;            // ~5 MiB/thread

  private static sinks: LogSink[] = [new HilogSink()];
  private static fileEnabled: boolean = false;

  static setLevel(level: LogLevel): void {
    Logger.level = level;
  }

  static addSink(sink: LogSink): void {
    Logger.sinks.push(sink);
  }

  static removeSink(sink: LogSink): void {
    const index = Logger.sinks.indexOf(sink);
    if (index >= 0) Logger.sinks.splice(index, 1);
  }

  /** Activate the rotating file sink (idempotent within a thread). */
  static enableFileSink(dir: string, baseName: string, level: LogLevel): void {
    if (Logger.fileEnabled) {
      return;
    }
    Logger.addSink(new FileSink(dir, baseName, level, Logger.fileMaxBytes, Logger.fileMaxFiles));
    Logger.fileEnabled = true;
  }

  static d(tag: string, message: string): void {
    Logger.emit(LogLevel.DEBUG, tag, message);
  }

  static i(tag: string, message: string): void {
    Logger.emit(LogLevel.INFO, tag, message);
  }

  static w(tag: string, message: string): void {
    Logger.emit(LogLevel.WARN, tag, message);
  }

  static e(tag: string, message: string): void {
    Logger.emit(LogLevel.ERROR, tag, message);
  }

  static f(tag: string, message: string): void {
    Logger.emit(LogLevel.FATAL, tag, message);
  }

  /** Short deterministic correlation token; pseudonymous rather than anonymized. */
  static mask(value: string): string {
    if (value.length === 0) {
      return '#empty';
    }
    let hash = 0x811c9dc5;
    for (let i = 0; i < value.length; i++) {
      hash = hash ^ value.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    let token = (hash >>> 0).toString(16);
    while (token.length < 4) {
      token = '0' + token;
    }
    return '#' + token.substring(0, 4);
  }

  static errorToken(error: Object): string {
    const message = error instanceof Error ? error.message : String(error);
    return Logger.mask(message);
  }

  private static emit(level: LogLevel, tag: string, message: string): void {
    if (level < Logger.level) {
      return;
    }
    const ts = Date.now();
    for (let i = 0; i < Logger.sinks.length; i++) {
      Logger.sinks[i].write(level, tag, message, ts);
    }
  }
}
