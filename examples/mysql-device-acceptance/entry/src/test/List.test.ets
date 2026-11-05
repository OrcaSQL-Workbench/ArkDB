import deviceAcceptanceRunnerTest from
  './acceptance/DeviceAcceptanceRunner.test';
import deviceReceiptClipboardTest from
  './evidence/DeviceReceiptClipboard.test';
import deviceReceiptSignerTest from './evidence/DeviceReceiptSigner.test';

export default function testsuite(): void {
  deviceAcceptanceRunnerTest();
  deviceReceiptClipboardTest();
  deviceReceiptSignerTest();
}
