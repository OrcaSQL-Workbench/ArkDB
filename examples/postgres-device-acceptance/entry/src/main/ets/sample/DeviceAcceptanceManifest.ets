export const DEVICE_ACCEPTANCE_SUITE_ID: string = 'arkdb.postgresql.device-acceptance';
export const DEVICE_ACCEPTANCE_CASE_IDS: string[] = [
  'tls_identity',
  'tls_hostname_mismatch',
  'server_error',
  'prepared_values',
  'authorized_schema',
  'cancellation',
  'cleanup'
];
export const DEVICE_ACCEPTANCE_DEVICE_TYPES: string[] = ['tablet', '2in1'];
export const DEVICE_ACCEPTANCE_MINIMUM_SDK: number = 24;
export const DEVICE_ACCEPTANCE_PROFILES: string[] = ['P15', 'P16', 'P17', 'P18'];
