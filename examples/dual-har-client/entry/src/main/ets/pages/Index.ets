import { MySqlDriverFactory } from '@arkdb/mysql';
import { PostgresDriverFactory } from '@arkdb/postgres';
import { isWorkerIsolationRetryBlocked, verifyWorkerIsolation } from '../WorkerIsolation';

@Entry
@Component
struct Index {
  @State private status: string = 'P27_WORKERS_PENDING';
  @State private running: boolean = false;
  @State private retryBlocked: boolean = false;
  private mysqlFactory: MySqlDriverFactory = new MySqlDriverFactory();
  private postgresFactory: PostgresDriverFactory = new PostgresDriverFactory();

  aboutToAppear(): void { this.runProbe(); }

  build() {
    Column({ space: 12 }) {
      Text('ArkDB dual-HAR consumer').fontSize(24).fontWeight(FontWeight.Bold)
      Text('MySQL factory: ' + this.mysqlFactory.driverId)
      Text('PostgreSQL factory: ' + this.postgresFactory.driverId)
      Text('Offline round trips, package identity, independent state and Worker replacement.')
      Button('Verify Worker isolation').enabled(!this.running && !this.retryBlocked)
        .onClick((): void => { this.runProbe(); })
      Text(this.status)
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }

  private async runProbe(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await verifyWorkerIsolation();
      this.status = 'P27_WORKERS_PASS';
      console.info(this.status);
    } catch (error) {
      this.retryBlocked = isWorkerIsolationRetryBlocked();
      const retryMessage = this.retryBlocked ? ' Restart the app before retrying.' : '';
      this.status = 'P27_WORKERS_FAIL: ' + (error instanceof Error ? error.message : String(error)) +
        retryMessage;
      console.error(this.status);
    } finally {
      this.running = false;
    }
  }
}
