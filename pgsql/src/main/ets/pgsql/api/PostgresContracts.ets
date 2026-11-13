import { ArkDbError, DriverCapabilities } from '@arkdb/core';
import { PostgresPreparedExecutor } from './PostgresPreparedContracts';

export class PostgresDriverCapabilities extends DriverCapabilities {
  supportsSsl: boolean = true;
}

export class PostgresConnectionFeatures {
  prepared?: PostgresPreparedExecutor;
}

export interface PostgresFeatureConnection {
  readonly postgresFeatures?: PostgresConnectionFeatures;
}

export function requirePostgresFeatures(
  connection: PostgresFeatureConnection): PostgresConnectionFeatures {
  const features = connection.postgresFeatures;
  if (features === undefined) {
    throw ArkDbError.unsupported('This connection does not provide PostgreSQL features.');
  }
  return features;
}
