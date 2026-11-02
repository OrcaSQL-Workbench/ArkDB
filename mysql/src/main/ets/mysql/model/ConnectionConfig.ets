import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { MySqlSessionOptions } from './MySqlSessionOptions';

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
  TlsVersions = 'tlsVersions',
  Session = 'session',
  SessionTimeZone = 'session.timeZone',
  SessionSqlMode = 'session.sqlMode',
  MultipleStatements = 'multipleStatements',
  PreparedCacheSize = 'preparedCacheSize'
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
  session?: MySqlSessionOptions;
  multipleStatements?: boolean = false;
  preparedCacheSize?: number;

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
    appendSessionValidationIssues(issues, this.session);
    appendMultipleStatementsValidationIssues(issues, this.multipleStatements);
    appendPreparedCacheValidationIssues(issues, this.preparedCacheSize);
    return issues;
  }

  clone(): ConnectionConfig {
    const c = new ConnectionConfig();
    c.host = this.host;
    c.port = this.port;
    c.user = this.user;
    c.defaultSchema = this.defaultSchema;
    c.ssl = this.ssl.clone();
    const session = this.session;
    if (session !== undefined) {
      const issues: ConnectionValidationIssue[] = [];
      appendSessionValidationIssues(issues, session);
      if (issues.length > 0) throw issues[0].error;
      c.session = new MySqlSessionOptions();
      c.session.timeZone = session.timeZone;
      c.session.sqlMode = session.sqlMode;
    }
    const multiStatementIssues: ConnectionValidationIssue[] = [];
    appendMultipleStatementsValidationIssues(multiStatementIssues, this.multipleStatements);
    if (multiStatementIssues.length > 0) throw multiStatementIssues[0].error;
    c.multipleStatements = this.multipleStatements;
    c.connectTimeoutMs = this.connectTimeoutMs;
    c.autocommit = this.autocommit;
    const cacheIssues: ConnectionValidationIssue[] = [];
    appendPreparedCacheValidationIssues(cacheIssues, this.preparedCacheSize);
    if (cacheIssues.length > 0) throw cacheIssues[0].error;
    c.preparedCacheSize = this.preparedCacheSize;
    return c;
  }
}

function appendMultipleStatementsValidationIssues(issues: ConnectionValidationIssue[],
  enabled: boolean | undefined): void {
  if (enabled !== undefined && typeof enabled !== 'boolean') {
    issues.push(new ConnectionValidationIssue(ConnectionConfigField.MultipleStatements,
      ArkDbError.validation('multipleStatements must be a boolean.')));
  }
}

function appendPreparedCacheValidationIssues(issues: ConnectionValidationIssue[],
  size: number | undefined): void {
  if (size !== undefined && (!Number.isSafeInteger(size) || size < 0 || size > 256)) {
    issues.push(new ConnectionValidationIssue(ConnectionConfigField.PreparedCacheSize,
      ArkDbError.validation('Prepared cache size must be an integer between 0 and 256.')));
  }
}

function appendSessionValidationIssues(issues: ConnectionValidationIssue[],
  session: MySqlSessionOptions | undefined): void {
  if (session === undefined) return;
  if (session === null || typeof session !== 'object' || Array.isArray(session)) {
    issues.push(new ConnectionValidationIssue(ConnectionConfigField.Session,
      ArkDbError.validation('Session options must be a non-null, non-array object.')));
    return;
  }
  if (!isValidSessionString(session.timeZone)) {
    issues.push(new ConnectionValidationIssue(ConnectionConfigField.SessionTimeZone,
      ArkDbError.validation('Session timeZone must be a primitive, well-formed string.')));
  }
  if (!isValidSessionString(session.sqlMode)) {
    issues.push(new ConnectionValidationIssue(ConnectionConfigField.SessionSqlMode,
      ArkDbError.validation('Session sqlMode must be a primitive, well-formed string.')));
  }
}

function isValidSessionString(value: string | undefined): boolean {
  if (value === undefined) return true;
  if (typeof value !== 'string') return false;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code >= 0xD800 && code <= 0xDBFF) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xDC00 || next > 0xDFFF) return false;
      index++;
    } else if (code >= 0xDC00 && code <= 0xDFFF) {
      return false;
    }
  }
  return true;
}
