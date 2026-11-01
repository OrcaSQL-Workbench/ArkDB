@Sendable
export class SampleRequest {
  operation: string = 'read';
  host: string = '';
  port: number = 3306;
  user: string = '';
  password: string = '';
  schema: string = '';
  caCertPath: string = '';
}

@Sendable
export class SampleResponse {
  ok: boolean = false;
  text: string = '';
  errorKind: string = '';
}

@Sendable
export class DeviceAcceptanceRequest {
  operation: string = 'acceptance';
  host: string = '';
  port: number = 3306;
  user: string = '';
  password: string = '';
  schema: string = '';
  caCertPath: string = '';
  mismatchHost: string = '';
  profile: string = 'M1';
  features: string = '';
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
