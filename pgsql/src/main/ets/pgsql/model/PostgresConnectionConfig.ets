import { ArkDbError } from '@arkdb/core';

const postgresConnectionOptionPasswords:
  WeakMap<PostgresConnectionOptions, string> =
  new WeakMap<PostgresConnectionOptions, string>();

export enum PostgresSslMode {
  DISABLED = 'disabled',
  REQUIRED = 'required',
  VERIFY_CA = 'verify_ca',
  VERIFY_FULL = 'verify_full'
}

export class PostgresSslConfig {
  mode: PostgresSslMode = PostgresSslMode.VERIFY_FULL;
  caCertPath?: string;
  clientCertPath?: string;
  clientKeyPath?: string;
  tlsVersions?: string[];
  cipherSuites?: string;

  clone(): PostgresSslConfig {
    const config = new PostgresSslConfig();
    config.mode = this.mode;
    config.caCertPath = this.caCertPath;
    config.clientCertPath = this.clientCertPath;
    config.clientKeyPath = this.clientKeyPath;
    config.tlsVersions = this.tlsVersions?.slice();
    config.cipherSuites = this.cipherSuites;
    return config;
  }
}

export class PostgresConnectionConfig {
  host: string = '';
  port: number = 5432;
  user: string = '';
  database?: string;
  applicationName: string = 'arkdb';
  ssl: PostgresSslConfig = new PostgresSslConfig();
  connectTimeoutMs: number = 10000;
  /** Allows cleartext-password responses only over active VERIFY_FULL TLS. */
  allowCleartextPassword: boolean = false;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (this.host.trim().length === 0) {
      errors.push(ArkDbError.validation('Host is required.'));
    }
    if (!Number.isSafeInteger(this.port) || this.port < 1 || this.port > 65535) {
      errors.push(ArkDbError.validation('Port must be between 1 and 65535.'));
    }
    appendTextError(errors, 'User', this.user, true);
    if (this.database !== undefined) {
      appendTextError(errors, 'Database', this.database, false);
    }
    appendTextError(errors, 'Application name', this.applicationName, false);
    if (!Number.isSafeInteger(this.connectTimeoutMs) || this.connectTimeoutMs <= 0) {
      errors.push(ArkDbError.validation('Connect timeout must be a positive integer.'));
    }
    const hasClientCert = nonEmpty(this.ssl.clientCertPath);
    const hasClientKey = nonEmpty(this.ssl.clientKeyPath);
    if (hasClientCert !== hasClientKey) {
      errors.push(ArkDbError.validation(
        'Client certificate and private key must be configured together.'));
    }
    const versions = this.ssl.tlsVersions;
    if (versions !== undefined) {
      for (const version of versions) {
        if (version !== 'TLSv1.2' && version !== 'TLSv1.3') {
          errors.push(ArkDbError.validation('Unsupported TLS version: ' + version));
        }
      }
    }
    return errors;
  }

  clone(): PostgresConnectionConfig {
    const config = new PostgresConnectionConfig();
    config.host = this.host;
    config.port = this.port;
    config.user = this.user;
    config.database = this.database;
    config.applicationName = this.applicationName;
    config.ssl = this.ssl.clone();
    config.connectTimeoutMs = this.connectTimeoutMs;
    config.allowCleartextPassword = this.allowCleartextPassword;
    return config;
  }
}

export class PostgresConnectionOptions {
  readonly config: PostgresConnectionConfig;

  constructor(config: PostgresConnectionConfig, password: string) {
    this.config = config;
    postgresConnectionOptionPasswords.set(this, password);
  }

  get password(): string {
    const password = postgresConnectionOptionPasswords.get(this);
    if (password === undefined) {
      throw ArkDbError.protocol('PostgreSQL connection options lost their password.');
    }
    return password;
  }
}

function appendTextError(errors: ArkDbError[], label: string, value: string,
  required: boolean): void {
  if (required && value.trim().length === 0) {
    errors.push(ArkDbError.validation(label + ' is required.'));
    return;
  }
  if (!isWellFormedText(value)) {
    errors.push(ArkDbError.validation(label + ' must not contain NUL or malformed Unicode.'));
  }
}

function nonEmpty(value: string | undefined): boolean {
  return value !== undefined && value.trim().length > 0;
}

function isWellFormedText(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code === 0) return false;
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
