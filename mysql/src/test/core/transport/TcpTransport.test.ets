import { describe, it, expect } from '@ohos/hypium';
import { socket as platformSocket } from '@kit.NetworkKit';
import { cert as platformCert } from '@kit.DeviceCertificateKit';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  dnsNameFromSan, dnsNameMatchesHost, ipAddressBytes, TcpByteSender, MAX_RECEIVE_BUFFER_BYTES, TcpTransport
} from '../../../main/ets/mysql/transport/TcpTransport';
import { remainingPacketWriteTimeMs } from '../../../main/ets/mysql/protocol/PacketChannel';
import { SslConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';
import { MockX509Cert, cert } from '../../../mock/DeviceCertificateKit.mock';

class HangingSender implements TcpByteSender {
  send(data: Uint8Array): Promise<void> {
    return new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {});
  }
}

class DeferredSender implements TcpByteSender {
  private finish: (() => void) | null = null;

  send(data: Uint8Array): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      this.finish = resolve;
    });
  }

  complete(): void {
    if (this.finish !== null) this.finish();
    this.finish = null;
  }
}

class DeferredCertificate {
  private finish: ((value: platformSocket.X509CertRawData) => void) | null = null;

  read(): Promise<platformSocket.X509CertRawData> {
    return new Promise<platformSocket.X509CertRawData>(
      (resolve: (value: platformSocket.X509CertRawData) => void): void => {
        this.finish = resolve;
      });
  }

  complete(): void {
    const finish = this.finish;
    this.finish = null;
    if (finish !== null) finish(remoteCertificateFixture());
  }
}

class TlsOptionsSocket extends MockSocket {
  connectOptions: platformSocket.TLSConnectOptions | null = null;

  connect(options: Object): Promise<void> {
    this.connectOptions = options as platformSocket.TLSConnectOptions;
    return super.connect(options);
  }
}

class OperationOutcome {
  settled: boolean = false;
  error: ArkDbError | null = null;

  observe<T>(operation: Promise<T>): Promise<void> {
    return operation.then((): void => {
      this.settled = true;
    }, (error: Object): void => {
      this.settled = true;
      this.error = error as ArkDbError;
    });
  }
}

export default function tcpTransportTest() {
  describe('TcpTransport', () => {
    it('reportsAnUnconfiguredRemoteCertificateThroughTheSdkTypedSocket', 0, async () => {
      const tcp = platformSocket.constructTCPSocketInstance();
      const tls = platformSocket.constructTLSSocketInstance(tcp);
      let caught: Error | null = null;
      try {
        try {
          await tls.getRemoteCertificate();
        } catch (error) {
          caught = error as Error;
        }
        expect(caught !== null).assertTrue();
        expect(caught!.message).assertEqual('Synthetic remote certificate is not configured');
      } finally {
        await tls.close();
      }
    });

    it('preservesConfiguredRemoteCertificateBytesThroughTheSdkPromiseContract', 0, async () => {
      const configured = remoteCertificateFixture();
      const peer = new MockSocket();
      peer.remoteCertificateResult = Promise.resolve(configured);
      socket.nextTls = peer;
      const tcp = platformSocket.constructTCPSocketInstance();
      const tls = platformSocket.constructTLSSocketInstance(tcp);
      try {
        const received = await tls.getRemoteCertificate();
        expect(received.encodingFormat).assertEqual(platformCert.EncodingFormat.FORMAT_DER);
        assertBytes(received.data, [0x30, 0]);
        expect(peer.remoteCertificateCalls).assertEqual(1);
      } finally {
        socket.nextTls = null;
        await tls.close();
      }
    });

    it('verifiesDecodedCertificateIdentitiesThroughTheTlsUpgradePath', 0, async () => {
      for (let mode = 0; mode < 5; mode++) {
        const transport = new TcpTransport();
        await transport.connect('synthetic.invalid', 3306, 1000);
        transport.prepareTlsUpgrade();
        const peer = new MockSocket();
        peer.remoteCertificateResult = Promise.resolve(remoteCertificateFixture());
        socket.nextTls = peer;
        const certificate = new MockX509Cert();
        certificate.dnsNames = [asciiBytes('*.example.com', 0)];
        certificate.commonNames = ['nested.db.example.com'];
        if (mode === 2) certificate.missingSubjectAltNames = true;
        certificate.ipNames = [new Uint8Array([0x87, 4, 127, 0, 0, 1])];
        cert.nextCertificate = certificate;
        cert.createCalls = 0;
        const config = requiredTls();
        config.mode = SslMode.VERIFY_IDENTITY;
        const host = mode === 0 ? 'db.example.com' : mode < 3 ? 'nested.db.example.com' :
          mode === 3 ? '127.0.0.1' : '127.0.0.2';
        try {
          const error = await rejection(transport.upgradeToTls(host, 3306, config, 1000));
          expect(peer.remoteCertificateCalls).assertEqual(1);
          expect(cert.createCalls).assertEqual(1);
          if (mode === 1 || mode === 4) {
            expect(error !== null).assertTrue();
            expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
            expect(error!.message).assertEqual('TLS certificate does not match host ' + host);
            expect(peer.closeCalls).assertEqual(1);
            expect(await rejection(transport.read(1))).assertEqual(error);
          } else {
            expect(error === null).assertTrue();
            peer.emitMessage(new Uint8Array([42]));
            expect((await transport.read(1))[0]).assertEqual(42);
          }
        } finally {
          cert.nextCertificate = null;
          socket.nextTls = null;
          await transport.close();
        }
      }
    });

    it('failsClosedOnRemoteCertificateRetrievalAndDecodeFailures', 0, async () => {
      for (let mode = 0; mode < 4; mode++) {
        const transport = new TcpTransport();
        await transport.connect('synthetic.invalid', 3306, 1000);
        transport.prepareTlsUpgrade();
        const peer = new MockSocket();
        const failure = new Error('Synthetic certificate retrieval failure');
        if (mode === 0) peer.remoteCertificateFailure = failure;
        else if (mode === 1) peer.remoteCertificateResult = Promise.reject(failure);
        else {
          const encoded = remoteCertificateFixture();
          if (mode === 3) encoded.data = new Uint8Array([0]);
          peer.remoteCertificateResult = Promise.resolve(encoded);
        }
        cert.nextCertificate = null;
        if (mode === 3) cert.nextCertificate = new MockX509Cert();
        cert.createCalls = 0;
        socket.nextTls = peer;
        const config = requiredTls();
        config.mode = SslMode.VERIFY_IDENTITY;
        try {
          const error = await rejection(transport.upgradeToTls('db.example.com', 3306, config, 1000));
          expect(error !== null).assertTrue();
          expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
          expect(peer.remoteCertificateCalls).assertEqual(1);
          expect(cert.createCalls).assertEqual(mode >= 2 ? 1 : 0);
          expect(error!.message.startsWith('Could not verify TLS server identity:')).assertTrue();
          expect(peer.closeCalls).assertEqual(1);
          expect(peer.listenerCount).assertEqual(0);
        } finally {
          cert.nextCertificate = null;
          socket.nextTls = null;
          await transport.close();
        }
      }
    });

    it('retainsTerminalFailureWhileRemoteCertificateRetrievalIsPending', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      transport.prepareTlsUpgrade();
      const peer = new MockSocket();
      const deferred = new DeferredCertificate();
      peer.remoteCertificateResult = deferred.read();
      socket.nextTls = peer;
      const certificate = new MockX509Cert();
      certificate.dnsNames = [asciiBytes('db.example.com', 0)];
      cert.nextCertificate = certificate;
      const config = requiredTls();
      config.mode = SslMode.VERIFY_IDENTITY;
      const outcome = new OperationOutcome();
      const upgrade = outcome.observe(transport.upgradeToTls('db.example.com', 3306, config, 1000));
      try {
        await nextTask();
        expect(peer.remoteCertificateCalls).assertEqual(1);
        expect(outcome.settled).assertFalse();
        peer.emitError();
        await upgrade;
        expect(outcome.error !== null).assertTrue();
        expect(outcome.error!.kind).assertEqual(ArkDbErrorKind.Tls);
        const terminal = outcome.error;
        deferred.complete();
        await nextTask();
        expect(outcome.error === terminal).assertTrue();
        expect(await rejection(transport.read(1))).assertEqual(terminal);
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
      } finally {
        deferred.complete();
        cert.nextCertificate = null;
        socket.nextTls = null;
        await transport.close();
        await upgrade;
      }
    });

    it('abortsAHangingWriteAndConsumerWhenAReadDeadlineExpires', 0, async () => {
      const sender = new DeferredSender();
      const transport = new TcpTransport(sender, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      const writeOutcome = new OperationOutcome();
      const write = writeOutcome.observe(transport.write(new Uint8Array([1])));
      const consumerOutcome = new OperationOutcome();
      const consumer = consumerOutcome.observe(transport.runWhileOpen((): Promise<void> =>
        new Promise<void>((resolve: () => void): void => {})));
      try {
        peer.emitMessage(new Uint8Array([1]));
        const readOutcome = new OperationOutcome();
        await readOutcome.observe(transport.read(2, 1));
        await nextTask();
        expect(readOutcome.error !== null).assertTrue();
        expect(readOutcome.error!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(writeOutcome.settled).assertTrue();
        expect(writeOutcome.error === readOutcome.error).assertTrue();
        expect(consumerOutcome.settled).assertTrue();
        expect(consumerOutcome.error === readOutcome.error).assertTrue();
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
      } finally {
        sender.complete();
        await transport.close();
        await write;
        await consumer;
      }
    });

    it('closesWhenSocketDeliveriesExceedTheBudgetWithoutAReader', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        for (let index = 0; index < 32; index++) {
          peer.emitMessage(new Uint8Array(1024 * 1024));
        }
        peer.emitMessage(new Uint8Array([1]));
        let caught: ArkDbError | null = null;
        try {
          await transport.read(1, 100);
        } catch (error) {
          caught = error as ArkDbError;
        }
        expect(caught !== null).assertTrue();
        expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(caught!.message).assertEqual('Transport receive buffer exceeds client limit');
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
      } finally {
        await transport.close();
      }
    });

    it('acceptsExactly32MiBOfDistinctDeliveriesAndReusesTheBudgetAfterReading', 0, async () => {
      expect(MAX_RECEIVE_BUFFER_BYTES).assertEqual(32 * 1024 * 1024);
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        for (let index = 0; index < 32; index++) {
          const bytes = new Uint8Array(1024 * 1024);
          bytes[0] = index;
          bytes[bytes.length - 1] = index + 32;
          peer.emitMessage(bytes);
        }
        const result = await transport.read(32 * 1024 * 1024);
        expect(result.length).assertEqual(32 * 1024 * 1024);
        for (let index = 0; index < 32; index++) {
          expect(result[index * 1024 * 1024]).assertEqual(index);
          expect(result[(index + 1) * 1024 * 1024 - 1]).assertEqual(index + 32);
        }
        peer.emitMessage(new Uint8Array([99]));
        expect((await transport.read(1))[0]).assertEqual(99);
        expect(peer.closeCalls).assertEqual(0);
      } finally {
        await transport.close();
      }
    });

    it('preservesFragmentedCoalescedAndZeroLengthReadsAtTheExactBudget', 0, async () => {
      const transport = new TcpTransport(null, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        peer.emitMessage(new Uint8Array(0));
        expect((await transport.read(0)).length).assertEqual(0);
        peer.emitMessage(new Uint8Array([1, 2]));
        peer.emitMessage(new Uint8Array([3]));
        peer.emitMessage(new Uint8Array([4, 5, 6, 7, 8]));
        assertBytes(await transport.read(3), [1, 2, 3]);
        peer.emitMessage(new Uint8Array([9, 10, 11]));
        assertBytes(await transport.read(8), [4, 5, 6, 7, 8, 9, 10, 11]);
        const pending = transport.read(3, 100);
        peer.emitMessage(new Uint8Array([12]));
        peer.emitMessage(new Uint8Array([13, 14, 15, 16]));
        assertBytes(await pending, [12, 13, 14]);
        assertBytes(await transport.read(2), [15, 16]);
        expect(peer.closeCalls).assertEqual(0);
      } finally {
        await transport.close();
      }
    });

    it('coalescesManyOneByteSocketDeliveriesWithoutLosingBytes', 0, async () => {
      const transport = new TcpTransport(null, 131072);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      try {
        for (let index = 0; index < 131072; index++) {
          peer.emitMessage(new Uint8Array([index & 0xff]));
        }
        const bytes = await transport.read(131072);
        for (let index = 0; index < bytes.length; index++) {
          if (bytes[index] !== (index & 0xff)) throw new Error('Fragmented byte order changed');
        }
        expect(peer.closeCalls).assertEqual(0);
      } finally {
        await transport.close();
      }
    });

    it('rejectsInvalidReceiveLimitsAndImpossibleReadsWithoutStrandingAReader', 0, async () => {
      const invalid = [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 33554433];
      for (const limit of invalid) {
        let error: ArkDbError | null = null;
        try {
          new TcpTransport(null, limit);
        } catch (caught) {
          error = caught as ArkDbError;
        }
        expect(error !== null).assertTrue();
        expect(error!.kind).assertEqual(ArkDbErrorKind.Validation);
      }
      const transport = new TcpTransport(null, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      try {
        for (const length of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 9]) {
          const error = await rejection(transport.read(length));
          expect(error !== null).assertTrue();
          expect(error!.kind).assertEqual(ArkDbErrorKind.Validation);
        }
        const first = transport.read(2, 100);
        const concurrent = await rejection(transport.read(1));
        expect(concurrent!.kind).assertEqual(ArkDbErrorKind.Protocol);
        socket.latestTcp!.emitMessage(new Uint8Array([1, 2]));
        assertBytes(await first, [1, 2]);
      } finally {
        await transport.close();
      }
    });

    it('rejectsAnOversizedSingleDeliveryAndKeepsTheFirstTerminalError', 0, async () => {
      const transport = new TcpTransport(null, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      const pending = rejection(transport.read(8, 100));
      peer.emitMessage(new Uint8Array(9));
      const error = await pending;
      expect(error!.kind).assertEqual(ArkDbErrorKind.Protocol);
      peer.emitMessage(new Uint8Array([1, 2, 3]), true);
      peer.emitError(true);
      peer.emitClose(true);
      expect(await rejection(transport.read(1))).assertEqual(error);
      expect(await rejection(transport.write(new Uint8Array([1])))).assertEqual(error);
      await transport.close();
      await transport.close();
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
    });

    it('failsPendingReadsAndWritesOnLocalCloseRemoteCloseAndSocketError', 0, async () => {
      for (let terminal = 0; terminal < 3; terminal++) {
        const sender = new DeferredSender();
        const transport = new TcpTransport(sender, 8);
        await transport.connect('synthetic.invalid', 3306, 1000);
        const peer = socket.latestTcp!;
        const read = rejection(transport.read(2, 100));
        const write = rejection(transport.write(new Uint8Array([1]), 100));
        peer.emitMessage(new Uint8Array([1]));
        if (terminal === 0) await transport.close();
        else if (terminal === 1) peer.emitClose();
        else peer.emitError();
        const error = await read;
        expect(error!.kind).assertEqual(ArkDbErrorKind.Network);
        expect(await write).assertEqual(error);
        sender.complete();
        peer.emitMessage(new Uint8Array([2]), true);
        peer.emitError(true);
        expect(await rejection(transport.read(1))).assertEqual(error);
        await transport.close();
        expect(peer.closeCalls).assertEqual(terminal === 1 ? 0 : 1);
        expect(peer.listenerCount).assertEqual(0);
      }
    });

    it('passesConfiguredTlsVersionsUsingSdkProtocolValues', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = new TlsOptionsSocket();
      socket.nextTls = peer;
      try {
        transport.prepareTlsUpgrade();
        const config = requiredTls();
        config.tlsVersions = ['TLSv1.2', ' TLSv1.3 ', ''];
        await transport.upgradeToTls('synthetic.invalid', 3306, config, 1000);
        expect(peer.connectOptions !== null).assertTrue();
        const protocols = peer.connectOptions!.secureOptions.protocols;
        expect(protocols !== undefined).assertTrue();
        expect(protocols!.length).assertEqual(2);
        expect(protocols![0]).assertEqual('TLSv1.2');
        expect(protocols![1]).assertEqual('TLSv1.3');
      } finally {
        await transport.close();
      }
    });

    it('appliesTheSameBudgetToTlsAndIgnoresTransferredTcpCallbacks', 0, async () => {
      const transport = new TcpTransport(null, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const tcp = socket.latestTcp!;
      transport.prepareTlsUpgrade();
      tcp.emitMessage(new Uint8Array(9), true);
      await transport.upgradeToTls('synthetic.invalid', 3306, requiredTls(), 1000);
      const tls = socket.latestTls!;
      tcp.emitMessage(new Uint8Array(9), true);
      tcp.emitError(true);
      tcp.emitClose(true);
      tls.emitMessage(new Uint8Array([1, 2, 3, 4]));
      tls.emitMessage(new Uint8Array([5, 6, 7, 8]));
      assertBytes(await transport.read(8), [1, 2, 3, 4, 5, 6, 7, 8]);
      const pending = rejection(transport.read(8, 100));
      tls.emitMessage(new Uint8Array(4));
      tls.emitMessage(new Uint8Array(5));
      const error = await pending;
      expect(error!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error!.message).assertEqual('Transport receive buffer exceeds client limit');
      tls.emitMessage(new Uint8Array([1]), true);
      tls.emitError(true);
      expect(await rejection(transport.read(1))).assertEqual(error);
      await transport.close();
      expect(tls.closeCalls).assertEqual(1);
      expect(tls.listenerCount).assertEqual(0);
      expect(tcp.closeCalls).assertEqual(0);
      expect(tcp.listenerCount).assertEqual(0);
    });

    it('propagatesTcpAndTlsSendFailuresToReadersAndConsumers', 0, async () => {
      for (let mode = 0; mode < 2; mode++) {
        const transport = new TcpTransport(null, 8);
        await transport.connect('synthetic.invalid', 3306, 1000);
        let peer = socket.latestTcp!;
        if (mode === 1) {
          transport.prepareTlsUpgrade();
          await transport.upgradeToTls('synthetic.invalid', 3306, requiredTls(), 1000);
          peer = socket.latestTls!;
        }
        const pending = rejection(transport.read(2, 100));
        const consumer = rejection(transport.runWhileOpen((): Promise<void> =>
          new Promise<void>((resolve: () => void): void => {})));
        peer.sendFailure = new Error('Synthetic send failure');
        const error = await rejection(transport.write(new Uint8Array([1])));
        expect(error!.kind).assertEqual(mode === 0 ? ArkDbErrorKind.Network : ArkDbErrorKind.Tls);
        expect(await pending).assertEqual(error);
        expect(await consumer).assertEqual(error);
        await transport.close();
        expect(peer.closeCalls).assertEqual(1);
      }
    });

    it('preservesTlsSocketErrorsAndRejectsLateSendCompletions', 0, async () => {
      const transport = new TcpTransport(null, 8);
      await transport.connect('synthetic.invalid', 3306, 1000);
      transport.prepareTlsUpgrade();
      await transport.upgradeToTls('synthetic.invalid', 3306, requiredTls(), 1000);
      const peer = socket.latestTls!;
      const sender = new DeferredSender();
      peer.sendResult = sender.send(new Uint8Array([1]));
      const write = rejection(transport.write(new Uint8Array([1]), 100));
      const read = rejection(transport.read(2, 100));
      peer.emitError();
      const error = await read;
      expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(await write).assertEqual(error);
      sender.complete();
      await nextTask();
      expect(await rejection(transport.read(1))).assertEqual(error);
      await transport.close();
    });

    it('cancelsAnInFlightConnectAndDoesNotAcceptItsLateCompletion', 0, async () => {
      const peer = new MockSocket();
      const sender = new DeferredSender();
      peer.connectResult = sender.send(new Uint8Array(0));
      socket.nextTcp = peer;
      const transport = new TcpTransport();
      const connected = rejection(transport.connect('synthetic.invalid', 3306, 1000));
      await transport.close();
      const error = await connected;
      expect(error!.kind).assertEqual(ArkDbErrorKind.Network);
      sender.complete();
      peer.emitMessage(new Uint8Array([1]), true);
      await nextTask();
      expect(await rejection(transport.read(1))).assertEqual(error);
      expect(peer.closeCalls).assertEqual(1);
    });

    it('releasesSocketsAfterFailedTcpConnectOrTlsUpgrade', 0, async () => {
      const tcp = new MockSocket();
      tcp.connectFailure = new Error('Synthetic connect failure');
      socket.nextTcp = tcp;
      const failed = new TcpTransport();
      const tcpError = await rejection(failed.connect('synthetic.invalid', 3306, 1000));
      expect(tcpError!.kind).assertEqual(ArkDbErrorKind.Network);
      await failed.close();
      expect(tcp.closeCalls).assertEqual(1);
      expect(tcp.listenerCount).assertEqual(0);

      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      transport.prepareTlsUpgrade();
      const tls = new MockSocket();
      tls.connectFailure = new Error('Synthetic TLS failure');
      socket.nextTls = tls;
      const error = await rejection(transport.upgradeToTls('synthetic.invalid', 3306, requiredTls(), 1000));
      expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(await rejection(transport.read(1))).assertEqual(error);
      await transport.close();
      expect(tls.closeCalls).assertEqual(1);
      expect(tls.listenerCount).assertEqual(0);
    });

    it('surfacesCloseFailureRatherThanReportingSuccessfulCleanup', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      peer.closeFailure = new Error('Synthetic close failure');
      const pending = rejection(transport.read(1, 100));
      const closeError = await rejection(transport.close());
      expect(closeError!.kind).assertEqual(ArkDbErrorKind.Network);
      expect(closeError!.message).assertEqual('Socket close failed');
      expect((await pending)!.message).assertEqual('Connection closed');
      expect(peer.closeCalls).assertEqual(1);
      expect(peer.listenerCount).assertEqual(0);
      expect(await rejection(transport.close())).assertEqual(closeError);
    });

    it('boundsSocketCleanupEvenWhenThePlatformCloseNeverSettles', 0, async () => {
      const transport = new TcpTransport();
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      const deferred = new DeferredSender();
      peer.closeResult = deferred.send(new Uint8Array(0));
      const pending = rejection(transport.read(1, 5000));
      const outcome = new OperationOutcome();
      const close = outcome.observe(transport.close());
      try {
        expect((await pending)!.kind).assertEqual(ArkDbErrorKind.Network);
        await nextTask(1100);
        expect(outcome.settled).assertTrue();
        expect(outcome.error !== null).assertTrue();
        expect(outcome.error!.message).assertEqual('Socket close timed out');
        expect(peer.listenerCount).assertEqual(0);
      } finally {
        deferred.complete();
        await close;
      }
      expect(peer.closeCalls).assertEqual(1);
    });

    it('keepsSuccessfulConsumerOperationsAndTheirErrorsIndependent', 0, async () => {
      const transport = new TcpTransport();
      for (let index = 0; index < 100; index++) {
        expect(await transport.runWhileOpen((): Promise<number> => Promise.resolve(index))).assertEqual(index);
      }
      const expected = ArkDbError.cancelled('Synthetic consumer cancellation');
      expect(await rejection(transport.runWhileOpen((): Promise<void> =>
        Promise.reject(expected)))).assertEqual(expected);
      expect(await rejection(transport.runWhileOpen((): Promise<void> => {
        throw expected;
      }))).assertEqual(expected);
      expect(await transport.runWhileOpen((): Promise<number> => Promise.resolve(7))).assertEqual(7);
      await transport.close();
      let called = false;
      const error = await rejection(transport.runWhileOpen((): Promise<void> => {
        called = true;
        return Promise.resolve();
      }));
      expect(error!.kind).assertEqual(ArkDbErrorKind.Network);
      expect(called).assertFalse();
    });

    it('rejectsAndClearsAPendingReadAtItsDeadline', 0, async () => {
      const transport = new TcpTransport();
      let first: ArkDbError | null = null;
      try {
        await transport.read(1, 1);
      } catch (error) {
        first = error as ArkDbError;
      }
      expect(first !== null).assertTrue();
      expect(first!.kind).assertEqual(ArkDbErrorKind.Protocol);

      let second: ArkDbError | null = null;
      try {
        await transport.read(1, 1);
      } catch (error) {
        second = error as ArkDbError;
      }
      expect(second !== null).assertTrue();
      expect(second!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('rejectsAHangingSendAtItsDeadline', 0, async () => {
      const transport = new TcpTransport(new HangingSender());
      const pendingRead = transport.read(1);
      let writeError: ArkDbError | null = null;
      try {
        await transport.write(new Uint8Array(new ArrayBuffer(1)), 1);
      } catch (error) {
        writeError = error as ArkDbError;
      }
      let readError: ArkDbError | null = null;
      try {
        await pendingRead;
      } catch (error) {
        readError = error as ArkDbError;
      }

      expect(writeError !== null).assertTrue();
      expect(writeError!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(readError !== null).assertTrue();
      expect(readError!.kind).assertEqual(ArkDbErrorKind.Protocol);
      let laterError: ArkDbError | null = null;
      try {
        await transport.write(new Uint8Array(new ArrayBuffer(1)), 1);
      } catch (error) {
        laterError = error as ArkDbError;
      }
      expect(laterError !== null).assertTrue();
      expect(laterError!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('keepsOneDecreasingDeadlineAcrossPacketFrames', 0, () => {
      expect(remainingPacketWriteTimeMs(5000, 1000, 1100)).assertEqual(4900);
      expect(remainingPacketWriteTimeMs(5000, 1000, 1500)).assertEqual(4500);
      expect(remainingPacketWriteTimeMs(5000, 1000, 6100) <= 0).assertTrue();
    });

    it('matchesCertificateDnsNamesWithoutBroadeningWildcards', 0, () => {
      expect(dnsNameMatchesHost('db.example.com', 'DB.EXAMPLE.COM.')).assertTrue();
      expect(dnsNameMatchesHost('*.example.com', 'db.example.com')).assertTrue();
      expect(dnsNameMatchesHost('*.example.com', 'nested.db.example.com')).assertFalse();
      expect(dnsNameMatchesHost('*db.example.com', 'db.example.com')).assertFalse();
    });

    it('readsRawAndDerEncodedDnsSubjectAltNames', 0, () => {
      const raw = asciiBytes('db.example.com', 1);
      const der = new Uint8Array(raw.length + 1);
      der[0] = 0x82;
      der[1] = raw.length - 1;
      der.set(raw.subarray(0, raw.length - 1), 2);
      expect(dnsNameFromSan(raw)).assertEqual('db.example.com');
      expect(dnsNameFromSan(der)).assertEqual('db.example.com');
    });

    it('parsesIpLiteralsForCertificateIdentityMatching', 0, () => {
      const ipv4 = ipAddressBytes('127.0.0.1');
      expect(ipv4 !== null).assertTrue();
      expect(ipv4!.length).assertEqual(4);
      expect(ipv4![3]).assertEqual(1);

      const ipv6 = ipAddressBytes('[2001:db8::1]');
      expect(ipv6 !== null).assertTrue();
      expect(ipv6!.length).assertEqual(16);
      expect(ipv6![0]).assertEqual(0x20);
      expect(ipv6![15]).assertEqual(1);
      expect(ipAddressBytes('2001:db8::1::2') === null).assertTrue();
    });

  });
}

function asciiBytes(value: string, trailingZeroes: number): Uint8Array {
  const data = new Uint8Array(value.length + trailingZeroes);
  for (let index = 0; index < value.length; index++) data[index] = value.charCodeAt(index);
  return data;
}

function remoteCertificateFixture(): platformSocket.X509CertRawData {
  const encoded: platformSocket.X509CertRawData = {
    encodingFormat: platformCert.EncodingFormat.FORMAT_DER,
    data: new Uint8Array([0x30, 0])
  };
  return encoded;
}

function nextTask(delayMs: number = 0): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, delayMs);
  });
}

async function rejection<T>(operation: Promise<T>): Promise<ArkDbError | null> {
  try {
    await operation;
    return null;
  } catch (error) {
    return error as ArkDbError;
  }
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index++) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function requiredTls(): SslConfig {
  const config = new SslConfig();
  config.mode = SslMode.REQUIRED;
  return config;
}
