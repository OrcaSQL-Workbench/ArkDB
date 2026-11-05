import { MySqlExecutionObserver } from '../diagnostics/MySqlExecutionObserver';

/** Observer-only compatibility wrapper; field additions require an explicit contract change. */
export class MySqlConnectionExtensions {
  readonly executionObserver?: MySqlExecutionObserver;

  constructor(executionObserver?: MySqlExecutionObserver) {
    this.executionObserver = executionObserver;
  }
}
