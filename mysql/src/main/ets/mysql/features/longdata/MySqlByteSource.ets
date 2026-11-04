export interface MySqlByteSource {
  read(maxBytes: number): Promise<Uint8Array | null>;
  /**
   * Called exactly once. It must cause any pending read to settle before this
   * promise settles, so the upload owner can join both operations.
   */
  close(): Promise<void>;
}
