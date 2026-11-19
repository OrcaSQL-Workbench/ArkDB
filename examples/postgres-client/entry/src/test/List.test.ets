import publicInterfaceTest from './consumer/PublicInterface.test';
import sampleRunnerTest from './sample/SampleRunner.test';

export default function testsuite(): void {
  publicInterfaceTest();
  sampleRunnerTest();
}
