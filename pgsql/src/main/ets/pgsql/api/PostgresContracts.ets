import { ArkDbError, DriverCapabilities } from '@arkdb/core';

export class PostgresDriverCapabilities extends DriverCapabilities {}

export class PostgresConnectionFeatures {}

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
