/**
 * Rotating file sink — persists caller-provided messages to the app sandbox for
 * field troubleshooting without a debugger. Opt-in: created only when the app
 * calls `Logger.enableFileSink(dir, base, level)`.
 *
 * - Redaction belongs at the call site; this sink writes messages without content
 *   inspection. `Logger.mask()` values are pseudonymous, and audit coverage remains
 *   part of the release contract.
 * - Size-based rotation: when the active file reaches `maxBytes`, it rolls to
 *   `<base>.1.log` (shifting older siblings, pruning beyond `maxFiles`).
 * - Writes go through a serialized async queue so file I/O stays off the hot
 *   path; any file error degrades silently to hilog-only (logging never throws).
 */
import { fileIo } from '@kit.CoreFileKit';
import { LogLevel, LogSink } from './LogSink';

export class FileSink implements LogSink {
  private dir: string;
  private baseName: string;
  private level: LogLevel;
  private maxBytes: number;
  private maxFiles: number;
  private activePath: string;
  private queue: string[] = [];
  private writing: boolean = false;

  constructor(dir: string, baseName: string, level: LogLevel, maxBytes: number, maxFiles: number) {
    this.dir = dir;
    this.baseName = baseName;
    this.level = level;
    this.maxBytes = maxBytes;
    this.maxFiles = maxFiles;
    this.activePath = dir + '/' + baseName + '.log';
    this.ensureDir();
  }

  write(level: LogLevel, tag: string, message: string, timestampMs: number): void {
    if (level < this.level) {
      return;
    }
    this.queue.push(FileSink.formatLine(level, tag, message, timestampMs));
    this.drain();
  }

  /** Serialized drain — one writer at a time; new lines queued during a write
   *  are flushed on the next loop iteration. */
  private async drain(): Promise<void> {
    if (this.writing) {
      return;
    }
    this.writing = true;
    try {
      while (this.queue.length > 0) {
        const batch = this.queue.join('');
        this.queue = [];
        await this.appendWithRotation(batch);
      }
    } catch (e) {
      // Degrade silently to hilog-only; drop this batch rather than crash.
      this.queue = [];
    } finally {
      this.writing = false;
    }
  }

  private async appendWithRotation(text: string): Promise<void> {
    this.rotateIfNeeded();
    const file = fileIo.openSync(
      this.activePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND
    );
    try {
      await fileIo.write(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private rotateIfNeeded(): void {
    let size = 0;
    try {
      size = fileIo.statSync(this.activePath).size;
    } catch (e) {
      size = 0; // not created yet
    }
    if (size < this.maxBytes) {
      return;
    }
    // Prune the oldest, shift the rest down, then roll the active file to .1.
    this.unlinkQuiet(this.rolledPath(this.maxFiles));
    for (let i = this.maxFiles - 1; i >= 1; i--) {
      this.renameQuiet(this.rolledPath(i), this.rolledPath(i + 1));
    }
    this.renameQuiet(this.activePath, this.rolledPath(1));
  }

  private rolledPath(index: number): string {
    return this.dir + '/' + this.baseName + '.' + index + '.log';
  }

  private ensureDir(): void {
    try {
      if (!fileIo.accessSync(this.dir)) {
        fileIo.mkdirSync(this.dir, true);
      }
    } catch (e) {
      // ignore — first write will retry/degrade
    }
  }

  private unlinkQuiet(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // ignore
    }
  }

  private renameQuiet(from: string, to: string): void {
    try {
      if (fileIo.accessSync(from)) {
        fileIo.renameSync(from, to);
      }
    } catch (e) {
      // ignore
    }
  }

  private static formatLine(level: LogLevel, tag: string, message: string, timestampMs: number): string {
    const ts = new Date(timestampMs).toISOString();
    return ts + '  ' + FileSink.levelChar(level) + '  ' + FileSink.pad(tag, 14) + '  ' + message + '\n';
  }

  private static levelChar(level: LogLevel): string {
    switch (level) {
      case LogLevel.DEBUG:
        return 'D';
      case LogLevel.INFO:
        return 'I';
      case LogLevel.WARN:
        return 'W';
      case LogLevel.ERROR:
        return 'E';
      case LogLevel.FATAL:
        return 'F';
      default:
        return '?';
    }
  }

  private static pad(s: string, width: number): string {
    let r = s;
    while (r.length < width) {
      r = r + ' ';
    }
    return r;
  }
}
