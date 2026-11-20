import { PostgresConnectionConfig, PostgresSslMode } from '@arkdb/postgres';
import { DEVICE_ACCEPTANCE_PROFILES } from './DeviceAcceptanceManifest';
import { DeviceAcceptanceRequest } from './Messages';

export class DeviceAcceptanceRequestSnapshot {
  readonly config: PostgresConnectionConfig;
  readonly mismatchConfig: PostgresConnectionConfig;
  readonly schema: string;
  readonly profile: string;
  readonly signedHapSha256: string;
  readonly operatorEvidenceId: string;

  constructor(request: DeviceAcceptanceRequest) {
    this.config = makeConfig(request, request.host.trim());
    this.mismatchConfig = makeConfig(request, request.mismatchHost.trim());
    this.schema = request.schema.trim();
    this.profile = request.profile;
    this.signedHapSha256 = request.signedHapSha256;
    this.operatorEvidenceId = request.operatorEvidenceId;
  }

  valid(): boolean {
    return this.config.validate().length === 0 && this.mismatchConfig.validate().length === 0 &&
      this.config.host.toLowerCase() !== this.mismatchConfig.host.toLowerCase() &&
      this.schema.length > 0 && DEVICE_ACCEPTANCE_PROFILES.includes(this.profile) &&
      /^[0-9a-f]{64}$/.test(this.signedHapSha256) &&
      /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(this.operatorEvidenceId);
  }
}

function makeConfig(request: DeviceAcceptanceRequest, host: string): PostgresConnectionConfig {
  const config = new PostgresConnectionConfig();
  config.host = host;
  config.port = request.port;
  config.user = request.user;
  if (request.database.trim().length > 0) config.database = request.database.trim();
  config.ssl.mode = PostgresSslMode.VERIFY_FULL;
  if (request.caCertPath.trim().length > 0) config.ssl.caCertPath = request.caCertPath.trim();
  return config;
}
