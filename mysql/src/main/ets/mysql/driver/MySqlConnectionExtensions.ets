import { MySqlExecutionObserver } from '../diagnostics/MySqlExecutionObserver';

export class MySqlConnectionExtensions {
  readonly executionObserver?: MySqlExecutionObserver;

  constructor(executionObserver?: MySqlExecutionObserver) {
    this.executionObserver = executionObserver;
  }
}
