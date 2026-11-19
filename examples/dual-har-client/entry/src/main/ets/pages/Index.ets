import { MySqlDriverFactory } from '@arkdb/mysql';
import { PostgresDriverFactory } from '@arkdb/postgres';

@Entry
@Component
struct Index {
  private mysqlFactory: MySqlDriverFactory = new MySqlDriverFactory();
  private postgresFactory: PostgresDriverFactory = new PostgresDriverFactory();

  build() {
    Column({ space: 12 }) {
      Text('ArkDB dual-HAR consumer').fontSize(24).fontWeight(FontWeight.Bold)
      Text('MySQL factory: ' + this.mysqlFactory.driverId)
      Text('PostgreSQL factory: ' + this.postgresFactory.driverId)
      Text('Offline package-identity tests run separately. Worker isolation is not verified.')
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }

}
