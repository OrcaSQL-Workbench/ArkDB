import sampleRunnerTest from './SampleRunner.test';
import legacyPublicInterfaceTest from './LegacyPublicInterface.test';
import preparedPublicInterfaceTest from './PreparedPublicInterface.test';
import deviceAcceptanceRunnerTest from './DeviceAcceptanceRunner.test';
import deviceReceiptClipboardTest from './DeviceReceiptClipboard.test';
import deviceReceiptSignerTest from './DeviceReceiptSigner.test';

export default function testsuite(): void {
  sampleRunnerTest();
  legacyPublicInterfaceTest();
  preparedPublicInterfaceTest();
  deviceAcceptanceRunnerTest();
  deviceReceiptClipboardTest();
  deviceReceiptSignerTest();
}
