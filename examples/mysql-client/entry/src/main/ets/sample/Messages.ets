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
