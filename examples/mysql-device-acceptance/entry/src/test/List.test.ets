import deviceAcceptanceRunnerTest from './DeviceAcceptanceRunner.test';
import deviceReceiptClipboardTest from './DeviceReceiptClipboard.test';
import deviceReceiptSignerTest from './DeviceReceiptSigner.test';

export default function testsuite(): void {
  deviceAcceptanceRunnerTest();
  deviceReceiptClipboardTest();
  deviceReceiptSignerTest();
}
