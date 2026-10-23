import { ArkDbError } from '../model/ArkDbError';

export interface DbExecutionController {
  cancel(connectionHandle: string): Promise<void>;
  isInterruptionError(error: ArkDbError): boolean;
}