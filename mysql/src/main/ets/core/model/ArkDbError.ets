/**
 * Typed driver error shared by connections, transports, and providers.
 * `Server` errors carry the MySQL error code + 5-char SQLSTATE from an ERR packet.
 */
export enum ArkDbErrorKind {
  Network = 'network',
  Tls = 'tls',
  Auth = 'auth',
  Protocol = 'protocol',
  Server = 'server',
  Timeout = 'timeout',
  Cancelled = 'cancelled',
  Validation = 'validation'
}

/** Canonical error type for the whole engine. Throwable (extends Error). */
export class ArkDbError extends Error {
  kind: ArkDbErrorKind;
  code?: number;
  sqlState?: string;

  constructor(kind: ArkDbErrorKind, message: string, code?: number, sqlState?: string) {
    super(message);
    this.name = 'ArkDbError';
    this.kind = kind;
    this.code = code;
    this.sqlState = sqlState;
  }

  static network(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Network, message);
  }

  static tls(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Tls, message);
  }

  static auth(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Auth, message);
  }

  static protocol(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Protocol, message);
  }

  static timeout(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Timeout, message);
  }

  static cancelled(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Cancelled, message);
  }

  static validation(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Validation, message);
  }

  /** From a server ERR packet. */
  static server(message: string, code: number, sqlState: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Server, message, code, sqlState);
  }
}
