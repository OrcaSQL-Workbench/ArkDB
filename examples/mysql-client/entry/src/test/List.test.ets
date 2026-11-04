import sampleRunnerTest from './SampleRunner.test';
import legacyPublicInterfaceTest from './LegacyPublicInterface.test';
import preparedPublicInterfaceTest from './PreparedPublicInterface.test';

export default function testsuite(): void {
  sampleRunnerTest();
  legacyPublicInterfaceTest();
  preparedPublicInterfaceTest();
}
