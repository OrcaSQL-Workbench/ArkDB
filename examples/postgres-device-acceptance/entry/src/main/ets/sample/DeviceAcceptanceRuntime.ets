import { deviceInfo } from '@kit.BasicServicesKit';
import {
  PostgresConnectionConfig, PostgresConnectionOptions, PostgresDriverFactory
} from '@arkdb/postgres';
import { DevicePlatformInfo } from './DeviceAcceptanceValidation';
import { DeviceAcceptanceConnection, DeviceDelay } from './DeviceAcceptanceCases';

export interface DeviceAcceptanceFactory {
  createConnection(config: PostgresConnectionConfig, password: string): DeviceAcceptanceConnection;
}

export class DefaultDeviceAcceptanceFactory implements DeviceAcceptanceFactory {
  private readonly factory: PostgresDriverFactory = new PostgresDriverFactory();

  createConnection(config: PostgresConnectionConfig, password: string): DeviceAcceptanceConnection {
    return this.factory.create(new PostgresConnectionOptions(config, password));
  }
}

export interface DevicePlatformReader {
  read(): DevicePlatformInfo;
}

export class SystemDevicePlatformReader implements DevicePlatformReader {
  read(): DevicePlatformInfo {
    const info = new DevicePlatformInfo();
    info.deviceType = deviceInfo.deviceType;
    info.sdkApiVersion = deviceInfo.sdkApiVersion;
    info.osFullName = deviceInfo.osFullName;
    return info;
  }
}

export class SystemDeviceDelay implements DeviceDelay {
  async wait(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve): void => { setTimeout(resolve, milliseconds); });
  }
}
