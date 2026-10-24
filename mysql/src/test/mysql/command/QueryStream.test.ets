import { describe, it, expect } from '@ohos/hypium';
import {
  DatabaseSessionStatus, estimateSqlRowsBytes, QueryOptions, QueryResultMeta, QueryResultSink,
  QueryResultSummary, QueryRowChunk, QueryTruncation, ArkDbError, ArkDbErrorKind
} from '@arkdb/core';
import { parseQueryStream, parseResultSet } from '../../../main/ets/mysql/command/Query';
import { parseBufferedResultStream, parseResultStream } from '../../../main/ets/mysql/command/ResultStream';
import { BinaryRowDecoder } from '../../../main/ets/mysql/value/BinaryRowDecoder';
import { Capabilities, ColumnType, FieldFlag, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import { MysqlPacket, MysqlPacketSource, PacketChannel } from '../../../main/ets/mysql/protocol/PacketChannel';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';
import { SslConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';

class FixtureSource implements MysqlPacketSource {
  packets: MysqlPacket[];

  constructor(packets: MysqlPacket[]) {
    this.packets = packets;
  }

  async readPacket(): Promise<MysqlPacket> {
    const packet = this.packets.shift();
    if (packet === undefined) {
      throw new Error('Fixture packet queue exhausted');
    }
    return packet;
  }
}

class TimeoutTrackingSource implements MysqlPacketSource {
  packets: MysqlPacket[];
  timeouts: number[] = [];

  constructor(packets: MysqlPacket[]) {
    this.packets = packets;
  }

  async readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
    this.timeouts.push(timeoutMs);
    const packet = this.packets.shift();
    if (packet === undefined) throw new Error('Fixture packet queue exhausted');
    return packet;
  }
}

class RecordingSink implements QueryResultSink {
  starts: QueryResultMeta[] = [];
  chunks: QueryRowChunk[] = [];
  ends: QueryResultSummary[] = [];
  truncations: QueryTruncation[] = [];
  cancelOnTruncation: boolean = false;

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    this.starts.push(meta);
    await Promise.resolve();
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    await Promise.resolve();
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    await Promise.resolve();
    return this.cancelOnTruncation;
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.ends.push(summary);
    await Promise.resolve();
  }
}

class LegacySink implements QueryResultSink {
  ends: QueryResultSummary[] = [];

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    await Promise.resolve();
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    await Promise.resolve();
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.ends.push(summary);
    await Promise.resolve();
  }
}

class HangingTruncationSink extends RecordingSink {
  onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    return new Promise<boolean>((resolve: (value: boolean | PromiseLike<boolean>) => void,
      reject: (reason?: Object) => void): void => {});
  }
}

class HangingRowsSink extends RecordingSink {
  onRows(chunk: QueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    return new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {});
  }
}

class RejectingTruncationSink extends RecordingSink {
  onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    return Promise.reject(new Error('control unavailable'));
  }
}

class WithheldAckSink extends RecordingSink {
  private acknowledgeRows: (() => void) | null = null;

  onRows(chunk: QueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    return new Promise<void>((resolve: () => void): void => {
      this.acknowledgeRows = resolve;
    });
  }

  acknowledge(): void {
    const resolve = this.acknowledgeRows;
    this.acknowledgeRows = null;
    if (resolve !== null) resolve();
  }
}

class WithheldTruncationAckSink extends RecordingSink {
  private acknowledgeTruncation: ((cancel: boolean) => void) | null = null;

  onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    return new Promise<boolean>((resolve: (cancel: boolean) => void): void => {
      this.acknowledgeTruncation = resolve;
    });
  }

  acknowledge(): void {
    const resolve = this.acknowledgeTruncation;
    this.acknowledgeTruncation = null;
    if (resolve !== null) resolve(false);
  }
}

class TypedControlFailureSink extends RecordingSink {
  private synchronous: boolean;

  constructor(synchronous: boolean) {
    super();
    this.synchronous = synchronous;
  }

  onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    if (this.synchronous) throw ArkDbError.protocol('Synthetic control failure');
    return Promise.reject(ArkDbError.network('Synthetic control connection failure'));
  }
}

class CountingPacketSource implements MysqlPacketSource {
  reads: number = 0;
  private channel: PacketChannel;

  constructor(channel: PacketChannel) {
    this.channel = channel;
  }

  readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
    this.reads += 1;
    return this.channel.readPacket(timeoutMs);
  }

  runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    return this.channel.runWhileOpen<T>(operation);
  }
}

class CancelledRowsSink extends RecordingSink {
  onRows(chunk: QueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    return Promise.reject(ArkDbError.cancelled('Synthetic consumer cancellation'));
  }
}

class FailingRowsSink extends RecordingSink {
  failure: ArkDbError;

  constructor(failure: ArkDbError) {
    super();
    this.failure = failure;
  }

  onRows(chunk: QueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    return Promise.reject(this.failure);
  }
}

class StreamOutcome {
  completed: boolean = false;
  error: ArkDbError | null = null;
}

export default function queryStreamTest() {
  describe('queryStream', () => {
    it('stopsBeforeDrainingWhenTransportFailsDuringTruncationAck', 0, async () => {
      for (let mode = 0; mode < 3; mode++) {
        const transport = new TcpTransport(null, 1024);
        await transport.connect('synthetic.invalid', 3306, 1000);
        let peer = socket.latestTcp!;
        if (mode === 1) {
          transport.prepareTlsUpgrade();
          const ssl = new SslConfig();
          ssl.mode = SslMode.REQUIRED;
          await transport.upgradeToTls('synthetic.invalid', 3306, ssl, 1000);
          peer = socket.latestTls!;
        }
        const source = new CountingPacketSource(new PacketChannel(transport));
        const sink = new WithheldTruncationAckSink();
        const options = new QueryOptions();
        options.maxRows = 1;
        const outcome = new StreamOutcome();
        const query = parseQueryStream(source, Capabilities.PROTOCOL_41,
          options, sink).then((): void => {
          outcome.completed = true;
        }, (error: Object): void => {
          outcome.error = error as ArkDbError;
        });
        try {
          const packets = [
            packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
            textRow('one'), textRow('two')
          ];
          if (mode !== 0) packets.push(eofPacket(StatusFlags.AUTOCOMMIT, 0));
          deliverPackets(peer, packets);
          await nextTask();
          expect(sink.truncations.length).assertEqual(1);
          const readsBeforeFailure = source.reads;
          if (mode === 0) peer.emitClose();
          else if (mode === 1) peer.emitError();
          else peer.emitMessage(new Uint8Array(1025));
          await query;
          expect(outcome.error !== null).assertTrue();
          expect(outcome.error!.kind).assertEqual(mode === 0 ? ArkDbErrorKind.Network :
            mode === 1 ? ArkDbErrorKind.Tls : ArkDbErrorKind.Protocol);
          expect(outcome.completed).assertFalse();
          expect(sink.ends.length).assertEqual(0);
          expect(source.reads).assertEqual(readsBeforeFailure);
          const retained = await source.runWhileOpen((): Promise<number> => Promise.resolve(1))
            .then((): ArkDbError | null => null, (error: Object): ArkDbError | null => error as ArkDbError);
          expect(retained === outcome.error).assertTrue();
          sink.acknowledge();
          await nextTask();
          expect(sink.ends.length).assertEqual(0);
          expect(source.reads).assertEqual(readsBeforeFailure);
        } finally {
          sink.acknowledge();
          await transport.close();
          await query;
        }
      }
    });

    it('drainsOrdinaryTruncationControlFailuresWithoutClassifyingTheirErrorKindAsTerminal', 0, async () => {
      for (let mode = 0; mode < 2; mode++) {
        const transport = new TcpTransport(null, 1024);
        await transport.connect('synthetic.invalid', 3306, 1000);
        const sink = new TypedControlFailureSink(mode === 1);
        const options = new QueryOptions();
        options.maxRows = 1;
        const query = parseQueryStream(new PacketChannel(transport),
          Capabilities.PROTOCOL_41, options, sink);
        try {
          deliverPackets(socket.latestTcp!, [
            packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
            textRow('one'), textRow('two'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
          ]);
          const result = await query;
          expect(result.loadedRowCount).assertEqual(1);
          expect(result.rowCount).assertEqual(2);
          expect(sink.truncations.length).assertEqual(1);
          expect(sink.ends.length).assertEqual(1);
          expect(sink.ends[0].truncated).assertTrue();
          expect(await transport.runWhileOpen((): Promise<number> => Promise.resolve(1))).assertEqual(1);
        } finally {
          await transport.close();
        }
      }
    });

    it('failsOnReceiveOverflowBeforeAckAndNeverEmitsALateResultEnd', 0, async () => {
      const transport = new TcpTransport(null, 1024);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      const sink = new WithheldAckSink();
      const options = new QueryOptions();
      options.maxChunkRows = 1;
      const outcome = new StreamOutcome();
      const query = parseQueryStream(new PacketChannel(transport), Capabilities.PROTOCOL_41,
        options, sink).then((): void => {
        outcome.completed = true;
      }, (error: Object): void => {
        outcome.error = error as ArkDbError;
      });
      try {
        deliverPackets(peer, [
          packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
          textRow('one'), textRow('two')
        ]);
        await nextTask();
        expect(sink.chunks.length).assertEqual(1);

        peer.emitMessage(new Uint8Array(1024));
        peer.emitMessage(new Uint8Array([1]));
        await nextTask();
        expect(outcome.error !== null).assertTrue();
        expect(outcome.error!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(outcome.error!.message).assertEqual('Transport receive buffer exceeds client limit');
        expect(outcome.completed).assertFalse();
        expect(peer.closeCalls).assertEqual(1);
        sink.acknowledge();
        await nextTask();
        expect(sink.ends.length).assertEqual(0);
        expect(sink.chunks.length).assertEqual(1);
      } finally {
        sink.acknowledge();
        await transport.close();
        await query;
      }
    });

    it('finishesNormalMultiChunkSocketResultsOnlyAfterEachAck', 0, async () => {
      const transport = new TcpTransport(null, 1024);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const sink = new WithheldAckSink();
      const options = new QueryOptions();
      options.maxChunkRows = 1;
      const outcome = new StreamOutcome();
      const query = parseQueryStream(new PacketChannel(transport), Capabilities.PROTOCOL_41,
        options, sink).then((): void => {
        outcome.completed = true;
      }, (error: Object): void => {
        outcome.error = error as ArkDbError;
      });
      try {
        deliverPackets(socket.latestTcp!, [
          packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
          textRow('one'), textRow('two'), textRow('three'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]);
        for (let chunk = 1; chunk <= 3; chunk++) {
          await nextTask();
          expect(sink.chunks.length).assertEqual(chunk);
          expect(outcome.completed).assertFalse();
          expect(sink.ends.length).assertEqual(0);
          sink.acknowledge();
        }
        await query;
        expect(outcome.error === null).assertTrue();
        expect(outcome.completed).assertTrue();
        expect(sink.ends.length).assertEqual(1);
        expect(sink.ends[0].loadedRowCount).assertEqual(3);
        expect(socket.latestTcp!.closeCalls).assertEqual(0);
      } finally {
        sink.acknowledge();
        await transport.close();
        await query;
      }
    });

    it('rejectsSocketFailureDuringTheFinalAckWithoutALateSuccess', 0, async () => {
      for (let mode = 0; mode < 2; mode++) {
        const transport = new TcpTransport(null, 1024);
        await transport.connect('synthetic.invalid', 3306, 1000);
        let peer = socket.latestTcp!;
        if (mode === 1) {
          transport.prepareTlsUpgrade();
          const ssl = new SslConfig();
          ssl.mode = SslMode.REQUIRED;
          await transport.upgradeToTls('synthetic.invalid', 3306, ssl, 1000);
          peer = socket.latestTls!;
        }
        const sink = new WithheldAckSink();
        const outcome = new StreamOutcome();
        const query = parseQueryStream(new PacketChannel(transport), Capabilities.PROTOCOL_41,
          new QueryOptions(), sink).then((): void => {
          outcome.completed = true;
        }, (error: Object): void => {
          outcome.error = error as ArkDbError;
        });
        try {
          deliverPackets(peer, [
            packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
            textRow('last'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
          ]);
          await nextTask();
          expect(sink.chunks.length).assertEqual(1);
          if (mode === 0) peer.emitClose();
          else peer.emitError();
          await nextTask();
          expect(outcome.error !== null).assertTrue();
          expect(outcome.error!.kind).assertEqual(mode === 0 ?
            ArkDbErrorKind.Network : ArkDbErrorKind.Tls);
          sink.acknowledge();
          await query;
          await nextTask();
          expect(outcome.completed).assertFalse();
          expect(sink.ends.length).assertEqual(0);
        } finally {
          sink.acknowledge();
          await transport.close();
          await query;
        }
      }
    });

    it('propagatesConsumerCancellationWithoutEmittingResultEnd', 0, async () => {
      const transport = new TcpTransport(null, 1024);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const sink = new CancelledRowsSink();
      const query = parseQueryStream(new PacketChannel(transport), Capabilities.PROTOCOL_41,
        new QueryOptions(), sink).then((): ArkDbError | null => null,
        (error: Object): ArkDbError | null => error as ArkDbError);
      try {
        deliverPackets(socket.latestTcp!, [
          packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
          textRow('one'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]);
        const error = await query;
        expect(error !== null).assertTrue();
        expect(error!.kind).assertEqual(ArkDbErrorKind.Cancelled);
        expect(sink.ends.length).assertEqual(0);
        expect(await transport.runWhileOpen((): Promise<number> => Promise.resolve(1))).assertEqual(1);
      } finally {
        await transport.close();
      }
    });

    it('usesStableDecodedByteAccounting', 0, () => {
      const binary = new Uint8Array(new ArrayBuffer(3));
      binary[0] = 1;
      binary[1] = 2;
      binary[2] = 3;
      expect(estimateSqlRowsBytes([[null, 'ab', 42, 123n, binary]])).assertEqual(22);
    });

    it('keepsLegacySinksCompatibleWithoutTruncationCallback', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);
      const sink = new LegacySink();
      const options = new QueryOptions();
      options.maxRows = 1;

      await parseQueryStream(source, Capabilities.PROTOCOL_41, options, sink);

      expect(sink.ends.length).assertEqual(1);
      expect(sink.ends[0].truncated).assertTrue();
    });

    it('streamsClassicEofInBoundedChunks', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('name'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('alpha'), textRow('beta'), textRow('gamma'), eofPacket(StatusFlags.AUTOCOMMIT, 1)
      ]);
      const sink = new RecordingSink();
      const options = new QueryOptions();
      options.maxChunkRows = 2;
      const execution = await parseQueryStream(source, Capabilities.PROTOCOL_41, options, sink);

      expect(sink.starts.length).assertEqual(1);
      expect(sink.chunks.length).assertEqual(2);
      expect(sink.chunks[0].rows.length).assertEqual(2);
      expect(sink.chunks[1].rows.length).assertEqual(1);
      expect(sink.ends[0].warningCount).assertEqual(1);
      expect(sink.ends[0].status.autocommit).assertTrue();
      expect(sink.ends[0].status.inTransaction).assertFalse();
      expect(execution.rowCount).assertEqual(3);
      expect(execution.loadedRowCount).assertEqual(3);
      expect(source.packets.length).assertEqual(0);
    });

    it('doesNotInventInsertIdentifiersForEofRowResults', 0, async () => {
      const packets = [
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ];
      const sink = new RecordingSink();
      await parseQueryStream(new FixtureSource(packets.slice()), Capabilities.PROTOCOL_41,
        new QueryOptions(), sink);
      expect(sink.ends[0].lastInsertId === undefined).assertTrue();
      const buffered = await parseResultSet(new FixtureSource(packets.slice()), Capabilities.PROTOCOL_41);
      expect(buffered.lastInsertId).assertEqual(0n);
    });

    it('preservesInsertIdentifiersActuallyReportedByOkRowTerminators', 0, async () => {
      const terminator = packet(new PacketWriter().writeUInt8(0xfe).writeLenEncInt(0)
        .writeLenEncInt(27).writeUInt16(StatusFlags.AUTOCOMMIT).writeUInt16(0).toUint8Array());
      const sink = new RecordingSink();
      await parseQueryStream(new FixtureSource([
        packet(bytes(1)), columnPacket('value'), textRow('one'), terminator
      ]), Capabilities.PROTOCOL_41 | Capabilities.DEPRECATE_EOF, new QueryOptions(), sink);
      expect(sink.ends[0].lastInsertId).assertEqual(27n);
    });

    it('doesNotApplyDrainDeadlineBeforeTruncation', 0, async () => {
      const source = new TimeoutTrackingSource([
        packet(bytes(1)), columnPacket('name'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('alpha'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);

      await parseQueryStream(source, Capabilities.PROTOCOL_41,
        new QueryOptions(), new RecordingSink());

      for (const timeout of source.timeouts) expect(timeout).assertEqual(0);
    });

    it('keepsNullEmptyAndTextNullFramingDistinct', 0, () => {
      const nullValue = new PacketReader(nullRow().payload).readLenEncBytes();
      const emptyValue = new PacketReader(binaryRow().payload).readLenEncBytes();
      const textNull = new PacketReader(binaryRow(0x4e, 0x55, 0x4c, 0x4c).payload).readLenEncBytes();

      expect(nullValue === null).assertTrue();
      expect(emptyValue !== null).assertTrue();
      expect(emptyValue!.length).assertEqual(0);
      expect(textNull !== null).assertTrue();
      expect(textNull!.length).assertEqual(4);
    });

    it('drainsDeprecatedEofRowsPastLimit', 0, async () => {
      const status = StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS;
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), textRow('one'), textRow('two'), textRow('three'),
        okPacket(0xfe, status, 0)
      ]);
      const sink = new RecordingSink();
      const options = new QueryOptions();
      options.maxRows = 2;
      const capabilities = Capabilities.PROTOCOL_41 | Capabilities.DEPRECATE_EOF;
      const execution = await parseQueryStream(source, capabilities, options, sink);

      expect(sink.ends[0].rowCount).assertEqual(3);
      expect(sink.ends[0].loadedRowCount).assertEqual(2);
      expect(sink.ends[0].truncated).assertTrue();
      expect(sink.ends[0].truncationReason).assertEqual('rowLimit');
      expect(sink.truncations.length).assertEqual(1);
      expect(sink.truncations[0].reason).assertEqual('rowLimit');
      expect(execution.status.autocommit).assertTrue();
      expect(execution.status.inTransaction).assertTrue();
      expect(source.packets.length).assertEqual(0);
    });

    it('finishesTruncatedResultWhenEarlyCancellationReturns1317', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two'), errorPacket(1317, '70100', 'Query execution was interrupted')
      ]);
      const sink = new RecordingSink();
      sink.cancelOnTruncation = true;
      const options = new QueryOptions();
      options.maxRows = 1;
      const status = new DatabaseSessionStatus();
      status.autocommit = false;
      status.inTransaction = true;

      const execution = await parseQueryStream(source, Capabilities.PROTOCOL_41,
        options, sink, status);

      expect(sink.chunks.length).assertEqual(1);
      expect(sink.chunks[0].rows.length).assertEqual(1);
      expect(sink.truncations.length).assertEqual(1);
      expect(sink.truncations[0].reason).assertEqual('rowLimit');
      expect(sink.truncations[0].loadedRowCount).assertEqual(1);
      expect(sink.ends.length).assertEqual(1);
      expect(sink.ends[0].truncated).assertTrue();
      expect(sink.ends[0].truncationReason).assertEqual('rowLimit');
      expect(sink.ends[0].rowCountKnown).assertFalse();
      expect(sink.ends[0].rowCount).assertEqual(2);
      expect(sink.ends[0].loadedRowCount).assertEqual(1);
      expect(execution.status.autocommit).assertFalse();
      expect(execution.status.inTransaction).assertTrue();
      expect(execution.statusKnown).assertFalse();
      expect(source.packets.length).assertEqual(0);
    });

    it('acceptsTruncation1317AfterAMoreResultsBoundary', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two'),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        errorPacket(1317, '70100', 'Query execution was interrupted')
      ]);
      const sink = new RecordingSink();
      sink.cancelOnTruncation = true;
      const options = new QueryOptions();
      options.maxRows = 1;

      const execution = await parseQueryStream(source, Capabilities.PROTOCOL_41, options, sink);

      expect(execution.resultSetCount).assertEqual(1);
      expect(execution.rowCountKnown).assertFalse();
      expect(sink.ends.length).assertEqual(1);
      expect(sink.ends[0].truncated).assertTrue();
      expect(source.packets.length).assertEqual(0);
    });

    it('suppressesBufferedRowsFromLaterResultsBeforeTruncation1317', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('first'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two'),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        packet(bytes(1)), columnPacket('second'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('buffered'), errorPacket(1317, '70100', 'Query execution was interrupted')
      ]);
      const sink = new RecordingSink();
      sink.cancelOnTruncation = true;
      const options = new QueryOptions();
      options.maxRows = 1;

      const execution = await parseQueryStream(source, Capabilities.PROTOCOL_41, options, sink);

      expect(execution.resultSetCount).assertEqual(2);
      expect(sink.chunks.length).assertEqual(1);
      expect(sink.ends.length).assertEqual(2);
      expect(sink.ends[1].loadedRowCount).assertEqual(0);
      expect(sink.ends[1].truncated).assertTrue();
      expect(source.packets.length).assertEqual(0);
    });

    it('keepsFallbackDrainDeadlineAcrossLaterResultMetadata', 0, async () => {
      const source = new DeadlineSource([
        packet(bytes(1)), columnPacket('first'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two'),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        packet(bytes(1))
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41, options, new LegacySink());
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(source.lastTimeoutMs > 0).assertTrue();
      expect(source.lastTimeoutMs <= options.maxDrainTimeMs).assertTrue();
    });

    it('countsFallbackDrainBytesAcrossResultSetsAfterControlFailure', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('first'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        binaryRow(0x30), binaryRow(0x31),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        packet(bytes(1)), columnPacket('second'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        binaryRow(0x32), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainBytes = 3;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41,
          options, new RejectingTruncationSink());
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('consumesMultipleOkResults', 0, async () => {
      const source = new FixtureSource([
        okPacket(0x00, StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        okPacket(0x00, StatusFlags.AUTOCOMMIT, 2)
      ]);
      const sink = new RecordingSink();
      const execution = await parseQueryStream(source, Capabilities.PROTOCOL_41, new QueryOptions(), sink);

      expect(execution.resultSetCount).assertEqual(2);
      expect(sink.starts.length).assertEqual(2);
      expect(sink.ends.length).assertEqual(2);
      expect(sink.ends[1].warningCount).assertEqual(2);
      expect(source.packets.length).assertEqual(0);
    });

    it('truncatesAtDecodedByteBudget', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('payload', 63), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        binaryRow(0x61, 0x62, 0x63), binaryRow(0x64, 0x65, 0x66), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);
      const sink = new RecordingSink();
      const options = new QueryOptions();
      options.maxResultBytes = 4;
      await parseQueryStream(source, Capabilities.PROTOCOL_41, options, sink);

      expect(sink.ends[0].rowCount).assertEqual(2);
      expect(sink.ends[0].loadedRowCount).assertEqual(1);
      expect(sink.ends[0].loadedBytes).assertEqual(3);
      expect(sink.ends[0].truncated).assertTrue();
      expect(sink.ends[0].truncationReason).assertEqual('resultBytes');
      expect(sink.truncations.length).assertEqual(1);
      expect(sink.truncations[0].reason).assertEqual('resultBytes');
      expect(source.packets.length).assertEqual(0);
    });

    it('rejectsExcessiveResultSets', 0, async () => {
      const source = new FixtureSource([
        okPacket(0x00, StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        okPacket(0x00, StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        okPacket(0x00, StatusFlags.AUTOCOMMIT, 0)
      ]);
      const options = new QueryOptions();
      options.maxResultSets = 2;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41, options, new RecordingSink());
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(source.packets.length).assertEqual(1);
    });

    class DeadlineSource implements MysqlPacketSource {
      packets: MysqlPacket[];
      lastTimeoutMs: number = 0;

      constructor(packets: MysqlPacket[]) {
        this.packets = packets;
      }

      async readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
        const packet = this.packets.shift();
        if (packet !== undefined) return packet;
        this.lastTimeoutMs = timeoutMs;
        throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
      }
    }

    it('closesWhenDrainBudgetIsExceeded', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        binaryRow(0x31), binaryRow(0x31, 0x32, 0x33), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainBytes = 1;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41, options, new RecordingSink());
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('passesAFiniteDeadlineToDrainPacketReads', 0, async () => {
      const source = new DeadlineSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two')
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainTimeMs = 5000;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41, options, new LegacySink());
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(source.lastTimeoutMs > 0).assertTrue();
      expect(source.lastTimeoutMs <= 5000).assertTrue();
    });

    it('failsWhenTruncationCancellationExceedsTheDrainDeadline', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two')
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainTimeMs = 1;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41,
          options, new HangingTruncationSink());
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('failsWhenTheFinalChunkAckExceedsTheSameDrainDeadline', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        textRow('one'), textRow('two')
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainTimeMs = 1;
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41,
          options, new HangingRowsSink());
      } catch (error) {
        caught = error as ArkDbError;
      }

      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('surfacesTypedServerError', 0, async () => {
      const source = new FixtureSource([errorPacket(1064, '42000', 'syntax error')]);
      const sink = new RecordingSink();
      let caught: ArkDbError | null = null;
      try {
        await parseQueryStream(source, Capabilities.PROTOCOL_41, new QueryOptions(), sink);
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Server);
      expect(caught!.code).assertEqual(1064);
    });

    it('clonesNormalizedSessionStatus', 0, () => {
      const status = new DatabaseSessionStatus();
      status.autocommit = false;
      status.inTransaction = true;
      const copy = status.clone();
      expect(copy.autocommit).assertFalse();
      expect(copy.inTransaction).assertTrue();
    });

    it('streamsBinaryRowsWithClassicAndDeprecatedEof', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const packets = [packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG)];
        if (mode === 0) packets.push(eofPacket(StatusFlags.AUTOCOMMIT, 0));
        packets.push(binaryIntRow(42));
        packets.push(mode === 0 ? eofPacket(StatusFlags.AUTOCOMMIT, 2) :
          okPacket(0xfe, StatusFlags.AUTOCOMMIT, 2));
        const source = new FixtureSource(packets);
        const sink = new RecordingSink();
        const capabilities = Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0);
        const execution = await parseResultStream(source, capabilities, new QueryOptions(),
          sink, new BinaryRowDecoder());
        expect(sink.starts.length).assertEqual(1);
        expect(sink.starts[0].hasRows).assertTrue();
        expect(sink.chunks.length).assertEqual(1);
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(sink.ends[0].warningCount).assertEqual(2);
        expect(execution.loadedRowCount).assertEqual(1);
        expect(execution.rowCount).assertEqual(1);
        expect(execution.statusKnown).assertTrue();
        expect(source.packets.length).assertEqual(0);
      }
    });

    it('decodesEveryBinaryResultUsingItsActualMetadata', 0, async () => {
      const decoder = new BinaryRowDecoder();
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
        eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(-1),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
        packet(bytes(1)), columnPacket('value', 63, ColumnType.LONGLONG, FieldFlag.UNSIGNED),
        eofPacket(StatusFlags.AUTOCOMMIT, 0),
        packet(bytes(0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff)),
        eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]);
      const sink = new RecordingSink();
      const execution = await parseResultStream(source, Capabilities.PROTOCOL_41,
        new QueryOptions(), sink, decoder);
      expect(execution.resultSetCount).assertEqual(2);
      expect(sink.chunks[0].rows[0][0]).assertEqual(-1);
      expect(sink.chunks[1].rows[0][0] === 18446744073709551615n).assertTrue();
      expect(sink.starts[1].columns[0].nativeTypeName).assertEqual('BIGINT');
      const changed = await parseBufferedResultStream(new FixtureSource([
        packet(bytes(1)), columnPacket('value'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
        binaryStringRow('after DDL'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
      ]), Capabilities.PROTOCOL_41, decoder);
      expect(changed.rows[0][0]).assertEqual('after DDL');
      expect(changed.columns[0].type).assertEqual(ColumnType.VAR_STRING);
      expect(source.packets.length).assertEqual(0);
    });

    it('buffersMixedBinaryAndOkResultsWithoutChangingNativeDefaults', 0, async () => {
      const result = await parseBufferedResultStream(new FixtureSource([
        okPacket(0, StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 1),
        packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
        eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(42),
        eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 2),
        okPacket(0, StatusFlags.AUTOCOMMIT, 3)
      ]), Capabilities.PROTOCOL_41, new BinaryRowDecoder());
      expect(result.rows.length).assertEqual(0);
      expect(result.lastInsertId === 0n).assertTrue();
      expect(result.warningCount).assertEqual(1);
      expect(result.additionalResults.length).assertEqual(2);
      expect(result.additionalResults[0].rows[0][0]).assertEqual(42);
      expect(result.additionalResults[0].lastInsertId === 0n).assertTrue();
      expect(result.additionalResults[0].warningCount).assertEqual(2);
      expect(result.additionalResults[1].warningCount).assertEqual(3);
      expect(result.autocommit).assertTrue();
    });

    it('keepsFeLengthEncodedTextDataDistinctFromTerminators', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const packets = [packet(bytes(1)), columnPacket('value')];
        if (mode === 0) packets.push(eofPacket(StatusFlags.AUTOCOMMIT, 0));
        packets.push(packet(bytes(0xfe, 1, 0, 0, 0, 0, 0, 0, 0, 0x78)));
        packets.push(mode === 0 ? eofPacket(StatusFlags.AUTOCOMMIT, 0) :
          okPacket(0xfe, StatusFlags.AUTOCOMMIT, 0));
        const result = await parseResultSet(new FixtureSource(packets),
          Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        expect(result.rows.length).assertEqual(1);
        expect(result.rows[0][0]).assertEqual('x');
      }
    });

    it('sharesBinaryRowAndDecodedByteBudgetsAcrossResultDraining', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const source = new TimeoutTrackingSource([
          packet(bytes(1)), columnPacket('first', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(42), binaryIntRow(43),
          eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0),
          packet(bytes(1)), columnPacket('second'), eofPacket(StatusFlags.AUTOCOMMIT, 0),
          binaryStringRow('drained'), eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]);
        const options = new QueryOptions();
        if (mode === 0) options.maxRows = 1;
        else options.maxResultBytes = 8;
        const sink = new RecordingSink();
        const execution = await parseResultStream(source, Capabilities.PROTOCOL_41,
          options, sink, new BinaryRowDecoder());
        expect(execution.resultSetCount).assertEqual(2);
        expect(execution.rowCount).assertEqual(3);
        expect(execution.loadedRowCount).assertEqual(1);
        expect(execution.loadedBytes).assertEqual(8);
        expect(sink.chunks.length).assertEqual(1);
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(sink.ends[0].truncationReason).assertEqual(mode === 0 ? 'rowLimit' : 'resultBytes');
        expect(sink.ends[1].truncated).assertTrue();
        expect(sink.ends[1].loadedRowCount).assertEqual(0);
        expect(sink.truncations.length).assertEqual(1);
        expect(source.packets.length).assertEqual(0);
        for (let index = 0; index < source.timeouts.length; index += 1) {
          if (index < 5) expect(source.timeouts[index]).assertEqual(0);
          else {
            expect(source.timeouts[index] > 0).assertTrue();
            expect(source.timeouts[index] <= options.maxDrainTimeMs).assertTrue();
          }
        }
      }
    });

    it('boundsBinaryChunksUsingWirePayloadBytes', 0, async () => {
      for (let mode = 0; mode < 3; mode += 1) {
        const options = new QueryOptions();
        options.maxChunkRows = mode === 0 ? 2 : 100;
        options.maxChunkBytes = mode === 0 ? 100 : mode === 1 ? 12 : 11;
        const sink = new RecordingSink();
        await parseResultStream(new FixtureSource([
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(1), binaryIntRow(2), binaryIntRow(3),
          eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]), Capabilities.PROTOCOL_41, options, sink, new BinaryRowDecoder());
        expect(sink.chunks.length).assertEqual(mode === 2 ? 3 : 2);
        expect(sink.chunks[0].rowOffset).assertEqual(0);
        expect(sink.chunks[0].encodedBytes).assertEqual(mode === 2 ? 6 : 12);
        expect(sink.chunks[0].rows.length).assertEqual(mode === 2 ? 1 : 2);
        expect(sink.chunks[1].rowOffset).assertEqual(mode === 2 ? 1 : 2);
        expect(sink.chunks[1].encodedBytes).assertEqual(6);
        if (mode === 2) {
          expect(sink.chunks[2].rowOffset).assertEqual(2);
          expect(sink.chunks[2].encodedBytes).assertEqual(6);
        }
        expect(sink.ends[0].loadedBytes).assertEqual(24);
      }
    });

    it('rejectsBinaryResultSetAndDrainByteOverflows', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const options = new QueryOptions();
        const packets = [
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(1)
        ];
        if (mode === 0) {
          options.maxResultSets = 1;
          packets.push(eofPacket(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 0));
          packets.push(okPacket(0, StatusFlags.AUTOCOMMIT, 0));
        } else {
          options.maxRows = 1;
          options.maxDrainBytes = 10;
          packets.push(binaryIntRow(2));
          packets.push(eofPacket(StatusFlags.AUTOCOMMIT, 0));
        }
        const source = new FixtureSource(packets);
        let caught: ArkDbError | null = null;
        try {
          await parseResultStream(source, Capabilities.PROTOCOL_41,
            options, new RecordingSink(), new BinaryRowDecoder());
        } catch (error) {
          caught = error as ArkDbError;
        }
        expect(caught !== null).assertTrue();
        expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(caught!.message).assertEqual(mode === 0 ? 'Result-set count exceeds configured limit 1' :
          'Truncated result exceeded synchronization drain budget');
        if (mode === 0) expect(source.packets.length).assertEqual(1);
      }
    });

    it('preservesBinaryTruncation1317FallbackStatus', 0, async () => {
      const source = new FixtureSource([
        packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
        eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(1), binaryIntRow(2),
        errorPacket(1317, '70100', 'Query execution was interrupted')
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      const status = new DatabaseSessionStatus();
      status.autocommit = false;
      status.inTransaction = true;
      const sink = new RecordingSink();
      sink.cancelOnTruncation = true;
      const execution = await parseResultStream(source, Capabilities.PROTOCOL_41,
        options, sink, new BinaryRowDecoder(), status);
      expect(sink.chunks[0].rows[0][0]).assertEqual(1);
      expect(sink.ends.length).assertEqual(1);
      expect(sink.ends[0].rowCountKnown).assertFalse();
      expect(execution.rowCountKnown).assertFalse();
      expect(execution.statusKnown).assertFalse();
      expect(execution.status.autocommit).assertFalse();
      expect(execution.status.inTransaction).assertTrue();
      expect(execution.truncationInterrupted).assertTrue();
      expect(execution.synchronizationDeadlineMs > 0).assertTrue();
      expect(source.packets.length).assertEqual(0);
    });

    it('doesNotSwallowBinaryConsumerServerOrCancellationErrors', 0, async () => {
      const failures: ArkDbError[] = [
        ArkDbError.server('Consumer failure, not a server packet', 1317, '70100'),
        ArkDbError.cancelled('Consumer cancellation')
      ];
      for (const failure of failures) {
        const source = new FixtureSource([
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(1), binaryIntRow(2),
          eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]);
        const options = new QueryOptions();
        options.maxChunkRows = 1;
        const sink = new FailingRowsSink(failure);
        const caught = await parseResultStream(source, Capabilities.PROTOCOL_41,
          options, sink, new BinaryRowDecoder()).then((): Object | null => null,
          (error: Object): Object | null => error);
        expect(caught === failure).assertTrue();
        expect(sink.ends.length).assertEqual(0);
        expect(source.packets.length).assertEqual(1);
      }
    });

    it('failsBinaryPendingAckOnReceiveOverflowWithoutLateSuccess', 0, async () => {
      const transport = new TcpTransport(null, 1024);
      await transport.connect('synthetic.invalid', 3306, 1000);
      const peer = socket.latestTcp!;
      const sink = new WithheldAckSink();
      const outcome = new StreamOutcome();
      const query = parseResultStream(new PacketChannel(transport), Capabilities.PROTOCOL_41,
        new QueryOptions(), sink, new BinaryRowDecoder()).then((): void => {
        outcome.completed = true;
      }, (error: Object): void => {
        outcome.error = error as ArkDbError;
      });
      try {
        deliverPackets(peer, [
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(42), eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]);
        await nextTask();
        expect(sink.chunks.length).assertEqual(1);
        peer.emitMessage(new Uint8Array(1025));
        await query;
        expect(outcome.error !== null).assertTrue();
        expect(outcome.error!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(outcome.completed).assertFalse();
        expect(peer.closeCalls).assertEqual(1);
        sink.acknowledge();
        await nextTask();
        expect(sink.ends.length).assertEqual(0);
        expect(sink.chunks.length).assertEqual(1);
      } finally {
        sink.acknowledge();
        await transport.close();
        await query;
      }
    });

    it('boundsBinaryTruncationControlAndFinalAckByDrainTime', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const options = new QueryOptions();
        options.maxRows = 1;
        options.maxDrainTimeMs = 40;
        const sink: RecordingSink = mode === 0 ? new HangingTruncationSink() : new HangingRowsSink();
        let caught: ArkDbError | null = null;
        try {
          await parseResultStream(new FixtureSource([
            packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
            eofPacket(StatusFlags.AUTOCOMMIT, 0), binaryIntRow(1), binaryIntRow(2),
            eofPacket(StatusFlags.AUTOCOMMIT, 0)
          ]), Capabilities.PROTOCOL_41, options, sink, new BinaryRowDecoder());
        } catch (error) {
          caught = error as ArkDbError;
        }
        expect(caught !== null).assertTrue();
        expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(caught!.message).assertEqual('Truncated result exceeded synchronization drain time budget');
        expect(sink.ends.length).assertEqual(0);
      }
    });

    it('rejectsMalformedBinaryRowsWithoutEmittingASuccessEnd', 0, async () => {
      const sink = new RecordingSink();
      let caught: ArkDbError | null = null;
      try {
        await parseResultStream(new FixtureSource([
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), packet(bytes(0, 0, 1)),
          eofPacket(StatusFlags.AUTOCOMMIT, 0)
        ]), Capabilities.PROTOCOL_41, new QueryOptions(), sink, new BinaryRowDecoder());
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(sink.chunks.length).assertEqual(0);
      expect(sink.ends.length).assertEqual(0);
    });

    it('retainsBinaryServerNativeCodeAndSqlState', 0, async () => {
      let caught: ArkDbError | null = null;
      try {
        await parseResultStream(new FixtureSource([
          packet(bytes(1)), columnPacket('value', 45, ColumnType.LONG),
          eofPacket(StatusFlags.AUTOCOMMIT, 0), errorPacket(1064, '42000', 'synthetic syntax failure')
        ]), Capabilities.PROTOCOL_41, new QueryOptions(), new RecordingSink(), new BinaryRowDecoder());
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Server);
      expect(caught!.nativeCode).assertEqual(1064);
      expect(caught!.code).assertEqual(1064);
      expect(caught!.sqlState).assertEqual('42000');
    });

    it('preservesSharedResultBudgetDefaults', 0, () => {
      const options = new QueryOptions();
      expect(options.statementTimeoutMs).assertEqual(0);
      expect(options.maxRows).assertEqual(0);
      expect(options.maxChunkRows).assertEqual(200);
      expect(options.maxChunkBytes).assertEqual(262144);
      expect(options.maxResultBytes).assertEqual(33554432);
      expect(options.maxResultSets).assertEqual(64);
      expect(options.maxDrainBytes).assertEqual(33554432);
      expect(options.maxDrainTimeMs).assertEqual(5000);
    });
  });
}

function packet(payload: Uint8Array): MysqlPacket {
  return new MysqlPacket(0, payload);
}

function deliverPackets(peer: MockSocket, packets: MysqlPacket[]): void {
  for (let index = 0; index < packets.length; index++) {
    const payload = packets[index].payload;
    const frame = new Uint8Array(payload.length + 4);
    frame[0] = payload.length & 0xff;
    frame[1] = (payload.length >>> 8) & 0xff;
    frame[2] = (payload.length >>> 16) & 0xff;
    frame[3] = index;
    frame.set(payload, 4);
    peer.emitMessage(frame);
  }
}

function nextTask(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

function bytes(...values: number[]): Uint8Array {
  return new Uint8Array(values);
}

function columnPacket(name: string, charset: number = 45,
  type: number = ColumnType.VAR_STRING, flags: number = 0, decimals: number = 0): MysqlPacket {
  const writer = new PacketWriter();
  writer.writeLenEncString('def');
  writer.writeLenEncString('schema');
  writer.writeLenEncString('table');
  writer.writeLenEncString('table');
  writer.writeLenEncString(name);
  writer.writeLenEncString(name);
  writer.writeLenEncInt(12);
  writer.writeUInt16(charset);
  writer.writeUInt32(255);
  writer.writeUInt8(type);
  writer.writeUInt16(flags);
  writer.writeUInt8(decimals);
  writer.writeUInt16(0);
  return packet(writer.toUint8Array());
}

function textRow(value: string): MysqlPacket {
  const writer = new PacketWriter();
  writer.writeLenEncString(value);
  return packet(writer.toUint8Array());
}

function nullRow(): MysqlPacket {
  return packet(bytes(0xfb));
}

function eofPacket(statusFlags: number, warnings: number): MysqlPacket {
  const writer = new PacketWriter();
  writer.writeUInt8(0xfe);
  writer.writeUInt16(warnings);
  writer.writeUInt16(statusFlags);
  return packet(writer.toUint8Array());
}

function okPacket(header: number, statusFlags: number, warnings: number): MysqlPacket {
  const writer = new PacketWriter();
  writer.writeUInt8(header);
  writer.writeLenEncInt(0);
  writer.writeLenEncInt(0);
  writer.writeUInt16(statusFlags);
  writer.writeUInt16(warnings);
  return packet(writer.toUint8Array());
}

function errorPacket(code: number, sqlState: string, message: string): MysqlPacket {
  const writer = new PacketWriter();
  writer.writeUInt8(0xff);
  writer.writeUInt16(code);
  writer.writeUInt8(0x23);
  writer.writeString(sqlState);
  writer.writeString(message);
  return packet(writer.toUint8Array());
}

function binaryRow(...value: number[]): MysqlPacket {
  const payload = new Uint8Array(value.length + 1);
  payload[0] = value.length;
  for (let index = 0; index < value.length; index += 1) {
    payload[index + 1] = value[index];
  }
  return packet(payload);
}

function binaryIntRow(value: number): MysqlPacket {
  return packet(new PacketWriter().writeUInt8(0).writeUInt8(0).writeInt32(value).toUint8Array());
}

function binaryStringRow(value: string): MysqlPacket {
  return packet(new PacketWriter().writeUInt8(0).writeUInt8(0).writeLenEncString(value).toUint8Array());
}