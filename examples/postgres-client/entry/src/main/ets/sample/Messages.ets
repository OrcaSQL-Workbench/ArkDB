'use shared';

@Sendable
export class SampleRequest {
  operation: string = 'read';
  host: string = '';
  port: number = 5432;
  user: string = '';
  password: string = '';
  database: string = '';
  schema: string = '';
  caCertPath: string = '';
}

@Sendable
export class SampleResponse {
  ok: boolean = false;
  text: string = '';
  errorKind: string = '';
  requiresTermination: boolean = false;
}
