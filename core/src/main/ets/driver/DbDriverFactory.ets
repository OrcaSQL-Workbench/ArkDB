import { DbConnection } from '../connection/DbConnection';
import { DriverCapabilities } from './DriverCapabilities';

export interface DbDriverDescriptor {
  readonly driverId: string;
  readonly capabilities: DriverCapabilities;
}

/** Each adapter owns its concrete options, including its authentication shape. */
export interface DbDriverFactory<TOptions, TConnection extends DbConnection> extends DbDriverDescriptor {
  create(options: TOptions): TConnection;
}
