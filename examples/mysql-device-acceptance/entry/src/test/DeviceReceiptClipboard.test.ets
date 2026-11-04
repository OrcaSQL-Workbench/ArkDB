import { describe, expect, it } from '@ohos/hypium';
import {
  DeviceReceiptClipboardPort, DeviceReceiptExporter
} from '../main/ets/sample/DeviceReceiptClipboard';

export default function deviceReceiptClipboardTest(): void {
  describe('Device receipt export', () => {
    it('copiesTheExactReceiptJsonWithoutReformatting', 0, async () => {
      const clipboard = new FakeClipboard();
      const exporter = new DeviceReceiptExporter(clipboard);
      const receipt = '{"schemaVersion":1,"payload":"exact bytes"}';
      await exporter.copyExact(receipt);
      expect(clipboard.value).assertEqual(receipt);
    });

    it('rejectsMissingOrUnboundedReceiptText', 0, async () => {
      const exporter = new DeviceReceiptExporter(new FakeClipboard());
      let failures = 0;
      for (const value of ['', 'not-json', '{' + 'x'.repeat(1024 * 1024) + '}']) {
        try {
          await exporter.copyExact(value);
        } catch (error) {
          failures++;
        }
      }
      expect(failures).assertEqual(3);
    });
  });
}

class FakeClipboard implements DeviceReceiptClipboardPort {
  value: string = '';

  async write(text: string): Promise<void> {
    this.value = text;
  }
}
