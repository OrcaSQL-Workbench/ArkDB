import { ArkDbError } from '../model/ArkDbError';
import { DbConnection } from '../connection/DbConnection';
import { DbDriverDescriptor, DbDriverFactory } from './DbDriverFactory';

/** Discovery is untyped; the returned factory handle retains its options type. */
export class DbDriverRegistry {
  private descriptors: DbDriverDescriptor[] = [];

  register<TOptions, TConnection extends DbConnection>(
    factory: DbDriverFactory<TOptions, TConnection>): DbDriverFactory<TOptions, TConnection> {
    if (!/^[a-z][a-z0-9_-]*$/.test(factory.driverId)) {
      throw ArkDbError.validation('Invalid driver identifier.');
    }
    for (const descriptor of this.descriptors) {
      if (descriptor.driverId === factory.driverId) {
        throw ArkDbError.validation('Driver is already registered: ' + factory.driverId);
      }
    }
    this.descriptors.push(factory);
    return factory;
  }

  describe(driverId: string): DbDriverDescriptor {
    for (const descriptor of this.descriptors) {
      if (descriptor.driverId === driverId) return descriptor;
    }
    throw ArkDbError.unsupported('Driver is not registered: ' + driverId);
  }

  driverIds(): string[] {
    const ids: string[] = [];
    for (const descriptor of this.descriptors) ids.push(descriptor.driverId);
    return ids;
  }
}
