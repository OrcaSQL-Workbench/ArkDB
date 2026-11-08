import {
  PostgresConnectionConfig, PostgresConnectionOptions, PostgresDriverFactory
} from '@arkdb/postgres';

@Entry
@Component
struct Index {
  @State private status: string =
    'Ready to verify the registered PostgreSQL package skeleton.';

  private async verifySkeleton(): Promise<void> {
    const config = new PostgresConnectionConfig();
    config.host = 'offline.invalid';
    config.user = 'consumer';
    const factory = new PostgresDriverFactory();
    const connection = factory.create(new PostgresConnectionOptions(config, ''));
    await connection.close();
    this.status = factory.driverId + ' skeleton exports compiled and closed locally.';
  }

  build() {
    Column({ space: 12 }) {
      Text('ArkDB PostgreSQL skeleton verifier').fontSize(24)
      Button('Verify package skeleton')
        .onClick((): void => { this.verifySkeleton(); })
      Text(this.status)
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }
}
