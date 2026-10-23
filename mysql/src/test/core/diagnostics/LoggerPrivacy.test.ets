import { describe, expect, it } from '@ohos/hypium';
import { Logger } from '../../../main/ets/core/diagnostics/Logger';
import { LogLevel, LogSink, LogTag } from '../../../main/ets/core/diagnostics/LogSink';

class RecordingLogSink implements LogSink {
  messages: string[] = [];

  write(level: LogLevel, tag: string, message: string, timestampMs: number): void {
    this.messages.push(message);
  }
}

export default function loggerPrivacyTest() {
  describe('Logger privacy', () => {
    it('tokenizesExceptionMessagesWithoutDisclosure', 0, () => {
      const first = Logger.errorToken(new Error("syntax near 'private_customer'"));
      const second = Logger.errorToken(new Error("syntax near 'private_customer'"));
      expect(first.startsWith('#')).assertTrue();
      expect(first.includes('private_customer')).assertFalse();
      expect(first).assertEqual(second);
    });

    it('keepsExceptionCanaryOutOfRecordedLogs', 0, () => {
      const canary = 'tcp://privacy-canary.example.invalid:3306';
      const error = new Error('connect failed endpoint=' + canary);
      const token = Logger.errorToken(error);
      const sink = new RecordingLogSink();
      const previousLevel = Logger.level;
      Logger.addSink(sink);
      Logger.setLevel(LogLevel.DEBUG);
      try {
        Logger.w(LogTag.Net, 'tcp connect failed error=' + Logger.errorToken(error));
      } finally {
        Logger.removeSink(sink);
        Logger.setLevel(previousLevel);
      }
      expect(sink.messages.length).assertEqual(1);
      expect(sink.messages[0].includes(token)).assertTrue();
      expect(sink.messages[0].includes(canary)).assertFalse();
      Logger.setLevel(LogLevel.DEBUG);
      try {
        Logger.w(LogTag.Net, 'recording sink cleanup probe');
      } finally {
        Logger.setLevel(previousLevel);
      }
      expect(sink.messages.length).assertEqual(1);
    });
  });
}