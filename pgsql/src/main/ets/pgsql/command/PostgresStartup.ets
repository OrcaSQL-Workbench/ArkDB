import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  HarmonyPostgresAuthPlatform, PostgresAuthPlatform, PostgresScramClient, PostgresScramClientState,
  PostgresScramPort, buildPostgresCleartextPasswordResponse, buildPostgresMd5PasswordResponse
} from '../auth/PostgresAuthCrypto';
import { DefaultPostgresScramPort } from '../auth/PostgresSaslPrep';
import {
  PostgresStartupContext, PostgresStartupRunner, applyPostgresParameterStatus, postgresErrorFromResponse
} from '../execution/PostgresSettlements';
import { PostgresSslMode } from '../model/PostgresConnectionConfig';
import { PostgresFrontendSerializer, PostgresStartupParameter } from '../protocol/PostgresByteCodec';
import {
  PostgresAuthenticationCleartextPassword, PostgresAuthenticationMd5Password, PostgresAuthenticationOk,
  PostgresAuthenticationRequest, PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue,
  PostgresAuthenticationSaslFinal, PostgresBackendKeyData, PostgresBackendMessage, PostgresBackendParser,
  PostgresErrorResponse, PostgresMessage, PostgresNegotiateProtocolVersion, PostgresNoticeResponse,
  PostgresNotificationResponse, PostgresParameterStatus, PostgresReadyForQuery
} from '../protocol/PostgresMessageChannel';

const SCRAM_SHA_256: string = 'SCRAM-SHA-256';
const DEFAULT_AUTH_PLATFORM: PostgresAuthPlatform = new HarmonyPostgresAuthPlatform();

export type PostgresScramPortFactory = (platform: PostgresAuthPlatform) => PostgresScramPort;
function defaultScramPortFactory(platform: PostgresAuthPlatform): PostgresScramPort { return new DefaultPostgresScramPort(platform); }

export function createDefaultPostgresStartupRunner(authPlatform: PostgresAuthPlatform = DEFAULT_AUTH_PLATFORM,
  scramPortFactory: PostgresScramPortFactory = defaultScramPortFactory): PostgresStartupRunner {
  return (context: PostgresStartupContext): Promise<void> => runPostgresStartup(context, authPlatform, scramPortFactory);
}

export async function runPostgresStartup(context: PostgresStartupContext,
  authPlatform: PostgresAuthPlatform = DEFAULT_AUTH_PLATFORM,
  scramPortFactory: PostgresScramPortFactory = defaultScramPortFactory): Promise<void> {
  await negotiateTlsIfConfigured(context);
  assertStartupActive(context); context.enterAuthenticating();
  await writeExactBytes(context, PostgresFrontendSerializer.startup(buildStartupParameters(context)));
  let authenticated = false; let authExchangeStarted = false; let backendKeyReceived = false;
  let scram: PostgresScramClient | null = null;
  try {
    while (true) {
      const raw = await runStartupStep<PostgresMessage>(context, (): Promise<PostgresMessage> => context.channel.readMessage());
      const msg: PostgresBackendMessage = PostgresBackendParser.parse(raw);
      if (msg instanceof PostgresErrorResponse) throw postgresErrorFromResponse(msg);
      if (msg instanceof PostgresNegotiateProtocolVersion) {
        throw ArkDbError.unsupported('PostgreSQL protocol version or startup parameter negotiation is not supported.');
      }
      if (msg instanceof PostgresNoticeResponse) continue;
      if (!authenticated) {
        if (msg instanceof PostgresAuthenticationOk) {
          if (scram !== null && scram.state !== PostgresScramClientState.Finalized) {
            throw ArkDbError.auth('PostgreSQL server completed authentication before SCRAM server signature verification.');
          }
          authenticated = true; continue;
        }
        if (msg instanceof PostgresAuthenticationSasl) {
          if (authExchangeStarted) throw duplicateAuthChallenge();
          authExchangeStarted = true;
          if (!offersMechanism(msg.mechanisms, SCRAM_SHA_256)) throw ArkDbError.unsupported('PostgreSQL server does not offer SCRAM-SHA-256.');
          const pw = context.readPassword();
          if (pw.length === 0) throw ArkDbError.validation('Password is required for PostgreSQL SCRAM authentication.');
          const activeScram = new PostgresScramClient(context.config.user, pw, scramPortFactory(authPlatform));
          scram = activeScram; let clientFirst = new Uint8Array(0);
          try {
            clientFirst = await runStartupStep<Uint8Array>(context, (): Promise<Uint8Array> => activeScram.start(msg));
            await writeExactBytes(context, clientFirst);
          } finally { clientFirst.fill(0); }
          continue;
        }
        if (msg instanceof PostgresAuthenticationSaslContinue) {
          if (scram === null || scram.state !== PostgresScramClientState.Started) throw ArkDbError.protocol('Unexpected PostgreSQL SASLContinue message.');
          const activeScram = scram; let clientFinal = new Uint8Array(0);
          try {
            clientFinal = await runStartupStep<Uint8Array>(context, (): Promise<Uint8Array> => activeScram.continue(msg));
            await writeExactBytes(context, clientFinal);
          } finally { clientFinal.fill(0); }
          continue;
        }
        if (msg instanceof PostgresAuthenticationSaslFinal) {
          if (scram === null || scram.state !== PostgresScramClientState.Continued) throw ArkDbError.protocol('Unexpected PostgreSQL SASLFinal message.');
          assertStartupActive(context); scram.finalize(msg); continue;
        }
        if (msg instanceof PostgresAuthenticationMd5Password) {
          if (authExchangeStarted) throw duplicateAuthChallenge();
          authExchangeStarted = true; const pw = context.readPassword();
          if (pw.length === 0) throw ArkDbError.validation('Password is required for PostgreSQL MD5 authentication.');
          let payload = new Uint8Array(0);
          try {
            payload = await runStartupStep<Uint8Array>(context, (): Promise<Uint8Array> => buildPostgresMd5PasswordResponse(pw, context.config.user, msg.salt, authPlatform));
            await runStartupStep<void>(context, (): Promise<void> => context.channel.writeMessage(0x70, payload));
          } finally { payload.fill(0); }
          continue;
        }
        if (msg instanceof PostgresAuthenticationCleartextPassword) {
          if (authExchangeStarted) throw duplicateAuthChallenge();
          authExchangeStarted = true; const pw = context.readPassword();
          if (context.config.allowCleartextPassword && context.serverInfo.tlsActive && context.config.ssl.mode === PostgresSslMode.VERIFY_FULL && pw.length === 0) {
            throw ArkDbError.validation('Password is required for PostgreSQL cleartext password authentication.');
          }
          let payload = new Uint8Array(0);
          try {
            payload = buildPostgresCleartextPasswordResponse(pw, context.config.allowCleartextPassword, context.serverInfo.tlsActive, context.config.ssl.mode);
            await runStartupStep<void>(context, (): Promise<void> => context.channel.writeMessage(0x70, payload));
          } finally { payload.fill(0); }
          continue;
        }
        if (msg instanceof PostgresAuthenticationRequest) {
          if (authExchangeStarted) throw duplicateAuthChallenge();
          throw ArkDbError.unsupported('Unsupported PostgreSQL authentication method: ' + msg.code);
        }
        throw ArkDbError.protocol('Unexpected PostgreSQL backend message before AuthenticationOk.');
      }
      if (msg instanceof PostgresParameterStatus) { assertStartupActive(context); applyPostgresParameterStatus(context.serverInfo, msg); continue; }
      if (msg instanceof PostgresBackendKeyData) {
        if (backendKeyReceived) throw ArkDbError.protocol('Duplicate PostgreSQL BackendKeyData during startup.');
        backendKeyReceived = true; assertStartupActive(context); context.setBackendKeyData(msg.processId, msg.secretKey); continue;
      }
      if (msg instanceof PostgresNotificationResponse) continue;
      if (msg instanceof PostgresReadyForQuery) { assertStartupActive(context); context.applyReadyStatus(msg.status); return; }
      throw ArkDbError.protocol('Unexpected PostgreSQL backend message during post-authentication startup.');
    }
  } finally {
    if (scram !== null && scram.state === PostgresScramClientState.Continued) {
      try { scram.finalize(new PostgresAuthenticationSaslFinal(new Uint8Array(0))); } catch (_e) {}
    }
    scram = null;
  }
}

async function negotiateTlsIfConfigured(context: PostgresStartupContext): Promise<void> {
  const config = context.config;
  if (config.ssl.mode === PostgresSslMode.DISABLED) { assertStartupActive(context); context.serverInfo.tlsActive = false; return; }
  await writeExactBytes(context, PostgresFrontendSerializer.sslRequest());
  let reply: Uint8Array | null = null;
  try {
    reply = await runStartupStep<Uint8Array | null>(context, (): Promise<Uint8Array | null> => context.transport.read(1));
  } catch (error) {
    if (error instanceof ArkDbError && error.kind === ArkDbErrorKind.Protocol && error.message === 'PostgreSQL transport read was incomplete.') {
      throw ArkDbError.tls('PostgreSQL SSLRequest did not receive a 1-byte server reply.');
    }
    throw error as Error;
  }
  if (reply === null || reply.length !== 1) throw ArkDbError.tls('PostgreSQL SSLRequest did not receive a 1-byte server reply.');
  if (reply[0] === 0x53) {
    assertStartupActive(context);
    if (context.transport.prepareTlsUpgrade === undefined || context.transport.upgradeToTls === undefined) {
      throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
    }
    context.transport.prepareTlsUpgrade();
    await runStartupStep<void>(context, (): Promise<void> =>
      context.transport.upgradeToTls!(config.host, config.port, config.ssl, context.deadline.remainingMs()));
    assertStartupActive(context); context.serverInfo.tlsActive = true; return;
  }
  if (reply[0] === 0x4e) throw ArkDbError.tls('PostgreSQL server does not support TLS connections.', 'SSL_NOT_SUPPORTED');
  if (reply[0] === 0x45) throw ArkDbError.tls('PostgreSQL server rejected SSLRequest before TLS negotiation.', 'SSL_PRE_TLS_ERROR');
  throw ArkDbError.protocol('Unexpected PostgreSQL SSLRequest response byte.');
}

function buildStartupParameters(context: PostgresStartupContext): PostgresStartupParameter[] {
  const config = context.config;
  const database = config.database !== undefined && config.database.length > 0 ? config.database : config.user;
  const parameters: PostgresStartupParameter[] = [{ name: 'user', value: config.user }, { name: 'database', value: database }];
  if (config.applicationName.length > 0) parameters.push({ name: 'application_name', value: config.applicationName });
  parameters.push({ name: 'client_encoding', value: 'UTF8' });
  return parameters;
}

async function writeExactBytes(context: PostgresStartupContext, frame: Uint8Array): Promise<void> {
  const written = await runStartupStep<number>(context, (): Promise<number> => context.transport.write(frame));
  if (!Number.isSafeInteger(written) || written !== frame.length) {
    throw ArkDbError.protocol('PostgreSQL transport write was incomplete.');
  }
}
function runStartupStep<T>(context: PostgresStartupContext, operation: () => Promise<T>): Promise<T> {
  return context.deadline.wait<T>((): Promise<T> =>
    context.settlement.raceClose<T>((): Promise<T> => { context.deadline.remainingMs(); return operation(); }));
}
function assertStartupActive(context: PostgresStartupContext): void {
  if (context.settlement.closeReason !== null) throw context.settlement.closeReason;
  if (context.settlement.isSettled) throw ArkDbError.protocol('PostgreSQL command settlement is already settled.');
  context.deadline.remainingMs();
}
function offersMechanism(mechanisms: string[], expected: string): boolean {
  for (const m of mechanisms) { if (m === expected) return true; }
  return false;
}
function duplicateAuthChallenge(): ArkDbError {
  return ArkDbError.protocol('Unexpected duplicate PostgreSQL authentication challenge.');
}
