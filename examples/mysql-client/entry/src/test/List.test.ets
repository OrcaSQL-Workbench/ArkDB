import sampleRunnerTest from './SampleRunner.test';
import legacyPublicInterfaceTest from './LegacyPublicInterface.test';

export default function testsuite(): void {
  sampleRunnerTest();
  legacyPublicInterfaceTest();
}
