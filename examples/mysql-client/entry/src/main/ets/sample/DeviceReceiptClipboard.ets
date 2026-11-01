import { pasteboard } from '@kit.BasicServicesKit';

export interface DeviceReceiptClipboardPort {
  write(text: string): Promise<void>;
}

class SystemDeviceReceiptClipboard implements DeviceReceiptClipboardPort {
  async write(text: string): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
  }
}

export class DeviceReceiptExporter {
  private clipboard: DeviceReceiptClipboardPort;

  constructor(clipboard: DeviceReceiptClipboardPort = new SystemDeviceReceiptClipboard()) {
    this.clipboard = clipboard;
  }

  async copyExact(receiptJson: string): Promise<void> {
    if (receiptJson.length === 0 || receiptJson.length > 1024 * 1024 ||
      !receiptJson.startsWith('{') || !receiptJson.endsWith('}')) {
      throw new Error('No bounded JSON receipt is available to copy.');
    }
    await this.clipboard.write(receiptJson);
  }
}
