/** Lifecycle of a single connection. */
export enum ConnectionState {
  Idle = 'idle',
  Connecting = 'connecting',
  Authenticating = 'authenticating',
  Ready = 'ready',
  Querying = 'querying',
  Closed = 'closed',
  Error = 'error'
}

/** Product identity established by an adapter, with no closed engine registry. */
export class ServerInfo {
  driverId: string = '';
  productName: string = '';
  connectionHandle: string = '';
  defaultEncoding: string = '';
  version: string = '';
  tlsActive: boolean = false;
}
