export class DriverCapabilities {
  supportsSsl: boolean = false;
  supportsCatalogs: boolean = false;
  supportsSchemas: boolean = false;
  supportsTransactions: boolean = false;
  supportsMetadata?: boolean = false;
  supportsMultipleResults: boolean = false;
  supportsStreamingResults: boolean = false;
  supportsGracefulCancel: boolean = false;
  /** @deprecated Retained for source compatibility; do not use capability flags for feature discovery. */
  supportsExplain: boolean = false;
  supportsPreparedStatements: boolean = false;
  supportsServerMetrics: boolean = false;
}
