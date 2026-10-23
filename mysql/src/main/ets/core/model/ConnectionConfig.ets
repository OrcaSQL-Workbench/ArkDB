import { ArkDbError, ArkDbErrorKind } from './ArkDbError';

/** SSL/TLS posture for a connection. String values are the canonical wire-style ids. */
export enum SslMode {
  DISABLED = 'disabled',
  PREFERRED = 'preferred',         // default — use TLS if the server offers it
  REQUIRED = 'required',           // fail if TLS is unavailable
  VERIFY_CA = 'verify_ca',         // require + verify the server cert against a CA
  VERIFY_IDENTITY = 'verify_identity' // verify_ca + hostname match
}

export enum ConnectionConfigField {
  Host = 'host',
  Port = 'port',
  User = 'user',
  ConnectTimeoutMs = 'connectTimeoutMs',
  ClientCredentials = 'clientCredentials',
  TlsVersions = 'tlsVersions'
}

export class ConnectionValidationIssue {
  field: ConnectionConfigField;
  error: ArkDbError;
  invalidValue?: string;

  constructor(field: ConnectionConfigField, error: ArkDbError, invalidValue?: string) {
    this.field = field;
    this.error = error;
    this.invalidValue = invalidValue;
  }
}

/** TLS material + policy. Used only when the selected mode negotiates TLS. */
export class SslConfig {
  mode: SslMode = SslMode.PREFERRED;
  caCertPath?: string;
  clientCertPath?: string;
  clientKeyPath?: string;
  tlsVersions?: string[];          // e.g. ['TLSv1.2', 'TLSv1.3']
  cipherSuites?: string;

  clone(): SslConfig {
    const c = new SslConfig();
    c.mode = this.mode;
    c.caCertPath = this.caCertPath;
    c.clientCertPath = this.clientCertPath;
    c.clientKeyPath = this.clientKeyPath;
    c.tlsVersions = this.tlsVersions !== undefined ? this.tlsVersions.slice() : undefined;
    c.cipherSuites = this.cipherSuites;
    return c;
  }
}

/**
 * Connection options implemented by the MySQL driver.
 * The caller owns profile metadata and credential storage; the password is passed separately.
 */
export class ConnectionConfig {
  host: string = '';
  port: number = 3306;
  user: string = '';
  defaultSchema?: string;
  ssl: SslConfig = new SslConfig();

  connectTimeoutMs: number = 10000;
  autocommit: boolean = true;
  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    for (const issue of this.validateIssues()) {
      errors.push(issue.error);
    }
    return errors;
  }

  validateIssues(): ConnectionValidationIssue[] {
    const issues: ConnectionValidationIssue[] = [];
    if (this.host.trim().length === 0) {
      issues.push(new ConnectionValidationIssue(ConnectionConfigField.Host,
        new ArkDbError(ArkDbErrorKind.Validation, 'Host is required')));
    }
    if (!Number.isSafeInteger(this.port) || this.port < 1 || this.port > 65535) {
      issues.push(new ConnectionValidationIssue(ConnectionConfigField.Port,
        new ArkDbError(ArkDbErrorKind.Validation, 'Port must be between 1 and 65535')));
    }
    if (this.user.trim().length === 0) {
      issues.push(new ConnectionValidationIssue(ConnectionConfigField.User,
        new ArkDbError(ArkDbErrorKind.Validation, 'Username is required')));
    }
    if (!Number.isSafeInteger(this.connectTimeoutMs) || this.connectTimeoutMs <= 0) {
      issues.push(new ConnectionValidationIssue(ConnectionConfigField.ConnectTimeoutMs,
        new ArkDbError(ArkDbErrorKind.Validation,
          'Connect timeout must be a positive integer')));
    }
    if (this.ssl.mode !== SslMode.DISABLED) {
      const hasClientCert = this.ssl.clientCertPath !== undefined &&
        this.ssl.clientCertPath.trim().length > 0;
      const hasClientKey = this.ssl.clientKeyPath !== undefined &&
        this.ssl.clientKeyPath.trim().length > 0;
      if (hasClientCert !== hasClientKey) {
        issues.push(new ConnectionValidationIssue(ConnectionConfigField.ClientCredentials,
          new ArkDbError(ArkDbErrorKind.Validation,
            'Client certificate and private key must be configured together')));
      }
      if (this.ssl.tlsVersions !== undefined) {
        for (const version of this.ssl.tlsVersions) {
          const normalized = version.trim();
          if (normalized.length === 0) continue;
          if (normalized !== 'TLSv1.2' && normalized !== 'TLSv1.3') {
            issues.push(new ConnectionValidationIssue(ConnectionConfigField.TlsVersions,
              new ArkDbError(ArkDbErrorKind.Validation,
                'Unsupported TLS version: ' + normalized), normalized));
          }
        }
      }
    }
    return issues;
  }

  clone(): ConnectionConfig {
    const c = new ConnectionConfig();
    c.host = this.host;
    c.port = this.port;
    c.user = this.user;
    c.defaultSchema = this.defaultSchema;
    c.ssl = this.ssl.clone();
    c.connectTimeoutMs = this.connectTimeoutMs;
    c.autocommit = this.autocommit;
    return c;
  }
}
