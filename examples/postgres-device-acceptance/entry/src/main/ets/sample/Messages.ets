@Sendable
export class DeviceAcceptanceRequest {
  operation: string = 'acceptance';
  host: string = '';
  port: number = 5432;
  user: string = '';
  password: string = '';
  database: string = '';
  schema: string = '';
  caCertPath: string = '';
  mismatchHost: string = '';
  profile: string = 'P17';
  signedHapSha256: string = '';
  operatorEvidenceId: string = '';
}

@Sendable
export class DeviceAcceptanceResponse {
  ok: boolean = false;
  text: string = '';
  errorKind: string = '';
  receiptJson: string = '';
  serverVersion: string = '';
  total: number = 0;
  passed: number = 0;
  failures: number = 0;
  errors: number = 0;
  ignored: number = 0;
}
