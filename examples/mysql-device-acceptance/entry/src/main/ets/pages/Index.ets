import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import {
  DeviceAcceptanceRequest, DeviceAcceptanceResponse
} from '../sample/Messages';
import { currentDeviceEvidenceBinding } from '../sample/DeviceEvidenceBinding';
import { DeviceReceiptExporter } from '../sample/DeviceReceiptClipboard';

@Entry
@Component
struct Index {
  @State private host: string = '';
  @State private port: string = '3306';
  @State private user: string = '';
  @State private password: string = '';
  @State private schema: string = '';
  @State private caCertPath: string = '';
  @State private mismatchHost: string = '';
  @State private profile: string = 'M1';
  @State private features: string = '';
  @State private signedHapSha256: string = '';
  @State private operatorEvidenceId: string = '';
  @State private receiptJson: string = '';
  @State private busy: boolean = false;
  @State private output: string = 'This source harness is unbound until device:prepare creates a one-time copy.';
  private deviceEvidenceBound: boolean = currentDeviceEvidenceBinding().enabled;
  private instance: worker.ThreadWorker | null = null;
  private stopTimer: number = -1;
  private receivedResponse: boolean = false;
  private receiptExporter: DeviceReceiptExporter = new DeviceReceiptExporter();

  aboutToDisappear(): void {
    this.password = '';
    const instance = this.instance;
    if (instance === null) return;
    const stop = new DeviceAcceptanceRequest();
    stop.operation = 'stop';
    try {
      instance.postMessage(stop);
    } catch (error) {
      console.error('ArkDB device acceptance could not deliver graceful shutdown.');
    }
    this.stopTimer = setTimeout((): void => {
      if (this.instance === instance) {
        console.error('ArkDB device acceptance forced Worker shutdown; execution outcome is not assumed.');
        this.terminate(instance);
      }
    }, 2000);
  }

  private runAcceptance(): void {
    if (this.busy || this.instance !== null || !this.deviceEvidenceBound) return;
    const request = new DeviceAcceptanceRequest();
    request.host = this.host.trim();
    request.port = Number(this.port);
    request.user = this.user;
    request.password = this.password;
    request.schema = this.schema.trim();
    request.caCertPath = this.caCertPath.trim();
    request.mismatchHost = this.mismatchHost.trim();
    request.profile = this.profile.trim().toUpperCase();
    request.features = this.features.trim();
    request.signedHapSha256 = this.signedHapSha256.trim().toLowerCase();
    request.operatorEvidenceId = this.operatorEvidenceId.trim();
    this.password = '';
    this.receiptJson = '';
    this.start(request);
  }

  private async copyReceipt(): Promise<void> {
    try {
      await this.receiptExporter.copyExact(this.receiptJson);
      this.output = 'Copied the exact signed receipt JSON. Clear the clipboard after secure transfer.';
    } catch (error) {
      this.output = 'The signed receipt could not be copied.';
    }
  }

  private start(request: DeviceAcceptanceRequest): void {
    this.busy = true;
    this.receivedResponse = false;
    this.output = 'Running the bound fixed-case device suite...';
    try {
      const instance = new worker.ThreadWorker('entry/ets/workers/device.worker.ets');
      this.instance = instance;
      instance.onmessage = (event: MessageEvents): void => {
        this.receivedResponse = true;
        const response: Object = event.data;
        if (response instanceof DeviceAcceptanceResponse) {
          this.receiptJson = response.receiptJson;
          this.output = (response.ok ? 'Receipt candidate completed\n' : 'Device suite did not pass\n') +
            response.text;
        } else {
          this.output = 'Invalid Worker response. No SQL was replayed.';
        }
      };
      instance.onerror = (_error: ErrorEvent): void => {
        this.output = 'Worker failure. The execution outcome is unknown; no SQL was replayed.';
        this.terminate(instance);
      };
      instance.onmessageerror = (): void => {
        this.output = 'Worker message could not be decoded. No SQL was replayed.';
        this.terminate(instance);
      };
      instance.onexit = (): void => {
        if (this.busy && !this.receivedResponse) {
          this.output = 'Worker exited without a result. The execution outcome is unknown.';
        }
        if (this.stopTimer >= 0) clearTimeout(this.stopTimer);
        this.stopTimer = -1;
        this.busy = false;
        if (this.instance === instance) this.instance = null;
      };
      instance.postMessage(request);
    } catch (error) {
      request.password = '';
      this.busy = false;
      this.output = 'Could not start the Worker. Check the acceptance Worker build configuration.';
      const instance = this.instance;
      if (instance !== null) this.terminate(instance);
    }
  }

  private terminate(instance: worker.ThreadWorker): void {
    if (this.instance !== instance) return;
    try {
      instance.terminate();
    } catch (error) {
      this.output += '\nWorker cleanup could not be confirmed.';
      console.error('ArkDB device acceptance Worker cleanup failed.');
    }
    this.busy = false;
    this.instance = null;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('ArkDB MySQL device acceptance').fontSize(26).fontWeight(FontWeight.Bold)
        Text(this.deviceEvidenceBound ?
          'This generated copy is bound to a one-time release challenge.' :
          'Source is unbound. Run device:prepare against a sealed release before use.')
          .fontSize(13)
        TextInput({ text: this.host, placeholder: 'Server hostname' })
          .onChange((value: string): void => { this.host = value; })
        TextInput({ text: this.port, placeholder: 'Port' })
          .type(InputType.Number).onChange((value: string): void => { this.port = value; })
        TextInput({ text: this.user, placeholder: 'Username' })
          .onChange((value: string): void => { this.user = value; })
        TextInput({ text: this.password, placeholder: 'Password (memory only)' })
          .type(InputType.Password).onChange((value: string): void => { this.password = value; })
        TextInput({ text: this.schema, placeholder: 'Authorized acceptance database' })
          .onChange((value: string): void => { this.schema = value; })
        TextInput({ text: this.caCertPath, placeholder: 'Sandbox-readable CA PEM path (optional)' })
          .onChange((value: string): void => { this.caCertPath = value; })
        TextInput({ text: this.mismatchHost, placeholder: 'TLS mismatch hostname from the approved test profile' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.mismatchHost = value; })
        TextInput({ text: this.profile, placeholder: 'Release profile: M1, M2, M3, or M4' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.profile = value; })
        TextInput({ text: this.features, placeholder: 'M4 product feature keys (comma-separated)' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.features = value; })
        TextInput({ text: this.signedHapSha256, placeholder: 'Actual signed/installed HAP SHA-256' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.signedHapSha256 = value; })
        TextInput({ text: this.operatorEvidenceId, placeholder: 'Operator build/sign/install evidence ID' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.operatorEvidenceId = value; })
        Button(this.busy ? 'Running...' : 'Run bound device acceptance')
          .enabled(!this.busy && this.deviceEvidenceBound)
          .onClick((): void => { this.runAcceptance(); })
        Button('Copy exact signed receipt JSON')
          .enabled(!this.busy && this.receiptJson.length > 0)
          .onClick((): void => { void this.copyReceipt(); })
        Text(this.output).width('100%').fontFamily('monospace').fontSize(14)
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }
}
