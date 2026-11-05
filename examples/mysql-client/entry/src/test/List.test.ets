import legacyPublicInterfaceTest from './consumer/LegacyPublicInterface.test';
import preparedPublicInterfaceTest from './consumer/PreparedPublicInterface.test';
import sampleRunnerTest from './sample/SampleRunner.test';

export default function testsuite(): void {
  legacyPublicInterfaceTest();
  preparedPublicInterfaceTest();
  sampleRunnerTest();
}
