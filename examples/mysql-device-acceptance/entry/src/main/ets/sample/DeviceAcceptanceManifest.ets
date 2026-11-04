export const DEVICE_ACCEPTANCE_SUITE_ID: string = 'arkdb.mysql.device-acceptance';
export const DEVICE_ACCEPTANCE_CASE_IDS: string[] = [
  'tls_identity',
  'tls_hostname_mismatch',
  'server_error',
  'eof_protocol',
  'binary_protocol',
  'authorized_schema',
  'cancellation',
  'cleanup'
];
export const DEVICE_ACCEPTANCE_DEVICE_TYPES: string[] = ['tablet', '2in1'];
export const DEVICE_ACCEPTANCE_SERVER_FAMILIES: string[] = ['MySQL'];
export const DEVICE_ACCEPTANCE_MINIMUM_SDK: number = 24;
