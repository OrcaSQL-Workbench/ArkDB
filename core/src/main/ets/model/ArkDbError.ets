/**
 * Typed driver error shared by connections, transports, and providers.
 * Native codes are optional and may be numeric or textual; SQLSTATE is independent.
 */
export enum ArkDbErrorKind {
  Network = 'network',
  Tls = 'tls',
  Auth = 'auth',
  Protocol = 'protocol',
  Server = 'server',
  Timeout = 'timeout',
  Cancelled = 'cancelled',
  Validation = 'validation',
  Unsupported = 'unsupported'
}

/** Canonical error type for the whole engine. Throwable (extends Error). */
export class ArkDbError extends Error {
  kind: ArkDbErrorKind;
  /** Numeric compatibility field; nativeCode also preserves textual identifiers. */
  code?: number;
  nativeCode?: number | string;
  sqlState?: string;

  constructor(kind: ArkDbErrorKind, message: string, code?: number | string, sqlState?: string) {
    super(message);
    this.name = 'ArkDbError';
    this.kind = kind;
    this.nativeCode = code;
    this.code = typeof code === 'number' ? code : undefined;
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

  static unsupported(message: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Unsupported, message);
  }

  static server(message: string, code?: number | string, sqlState?: string): ArkDbError {
    return new ArkDbError(ArkDbErrorKind.Server, message, code, sqlState);
  }
}
