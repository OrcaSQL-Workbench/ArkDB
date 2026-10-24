/**
 * Hilog sink — the always-on destination. Maps each LogLevel to the matching
 * `hilog` severity under the shared LOG_DOMAIN. `%{public}s` emits the complete
 * caller-provided message, so raw-value exclusion must happen before this sink;
 * mask tokens are pseudonymous and release audit coverage remains pending.
 *
 * hilog merges UI-thread and Worker-thread output into one filterable stream
 * (DevEco / hdc), so no cross-thread plumbing is needed.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LogLevel, LogSink, LOG_DOMAIN } from './LogSink';

export class HilogSink implements LogSink {
  write(level: LogLevel, tag: string, message: string, timestampMs: number): void {
    switch (level) {
      case LogLevel.DEBUG:
        hilog.debug(LOG_DOMAIN, tag, '%{public}s', message);
        break;
      case LogLevel.INFO:
        hilog.info(LOG_DOMAIN, tag, '%{public}s', message);
        break;
      case LogLevel.WARN:
        hilog.warn(LOG_DOMAIN, tag, '%{public}s', message);
        break;
      case LogLevel.ERROR:
        hilog.error(LOG_DOMAIN, tag, '%{public}s', message);
        break;
      case LogLevel.FATAL:
        hilog.fatal(LOG_DOMAIN, tag, '%{public}s', message);
        break;
      default:
        break;
    }
  }
}
