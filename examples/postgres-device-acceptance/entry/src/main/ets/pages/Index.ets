import { DeviceAcceptanceRequest } from '../sample/Messages';
import { currentDeviceEvidenceBinding } from '../sample/DeviceEvidenceBinding';
import { DeviceReceiptExporter } from '../sample/DeviceReceiptClipboard';
import { DeviceWorkerHost } from '../sample/DeviceWorkerHost';

@Entry
@Component
struct Index {
  @State private host: string = '';
  @State private port: string = '5432';
  @State private user: string = '';
  @State private password: string = '';
  @State private database: string = '';
  @State private schema: string = '';
  @State private caCertPath: string = '';
  @State private mismatchHost: string = '';
  @State private profile: string = 'P17';
  @State private signedHapSha256: string = '';
  @State private operatorEvidenceId: string = '';
  @State private receiptJson: string = '';
  @State private busy: boolean = false;
  @State private copying: boolean = false;
  @State private output: string =
    'This source harness is unbound until device:prepare creates a one-time copy.';
  private deviceEvidenceBound: boolean = currentDeviceEvidenceBinding().enabled;
  private instance: DeviceWorkerHost | null = null;
  private generation: number = 0;
  private receiptExporter: DeviceReceiptExporter = new DeviceReceiptExporter();

  aboutToDisappear(): void {
    this.stopForPageHide();
  }

  onPageHide(): void {
    this.stopForPageHide();
  }

  private stopForPageHide(): void {
    this.password = '';
    this.generation++;
    const instance = this.instance;
    if (instance === null) return;
    this.output = 'Acceptance was interrupted when the page became hidden.';
    void instance.stop().catch((): void => {
      console.error('ArkDB PostgreSQL acceptance Worker cleanup could not be confirmed.');
    });
  }

  private runAcceptance(): void {
    if (this.busy || this.copying || this.instance !== null || !this.deviceEvidenceBound) return;
    this.generation++;
    const request = new DeviceAcceptanceRequest();
    request.host = this.host.trim();
    request.port = Number(this.port);
    request.user = this.user;
    request.password = this.password;
    request.database = this.database.trim();
    request.schema = this.schema.trim();
    request.caCertPath = this.caCertPath.trim();
    request.mismatchHost = this.mismatchHost.trim();
    request.profile = this.profile.trim().toUpperCase();
    request.signedHapSha256 = this.signedHapSha256.trim().toLowerCase();
    request.operatorEvidenceId = this.operatorEvidenceId.trim();
    this.password = '';
    this.receiptJson = '';
    void this.start(request);
  }

  private async copyReceipt(): Promise<void> {
    if (this.copying || this.busy || this.receiptJson.length === 0) return;
    this.copying = true;
    const generation = this.generation;
    try {
      await this.receiptExporter.copyExact(this.receiptJson);
      if (generation === this.generation) {
        this.output = 'Copied the exact signed receipt JSON. Clear the clipboard after secure transfer.';
      }
    } catch (error) {
      if (generation === this.generation) this.output = 'The signed receipt could not be copied.';
    } finally {
      this.copying = false;
    }
  }

  private async start(request: DeviceAcceptanceRequest): Promise<void> {
    this.busy = true;
    const generation = this.generation;
    this.output = 'Running the bound fixed-case PostgreSQL suite...';
    try {
      const instance = new DeviceWorkerHost();
      this.instance = instance;
      const response = await instance.run(request);
      if (generation !== this.generation) return;
      this.receiptJson = response.receiptJson;
      this.output = (response.ok ? 'Receipt candidate completed\n' : 'Device suite did not pass\n') +
        response.text;
    } catch (_error) {
      if (generation === this.generation) {
        this.output = 'Worker execution or cleanup failed. The outcome is unknown; no SQL was replayed.';
      }
    } finally {
      request.password = '';
      this.busy = false;
      this.instance = null;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('ArkDB PostgreSQL device acceptance').fontSize(26).fontWeight(FontWeight.Bold)
        Text(this.deviceEvidenceBound ?
          'This generated copy is bound to a one-time release challenge.' :
          'Source is unbound. Run device:prepare against a sealed release before use.')
          .fontSize(13)
        TextInput({ text: this.host, placeholder: 'Verified PostgreSQL hostname' })
          .onChange((value: string): void => { this.host = value; })
        TextInput({ text: this.port, placeholder: 'Port' })
          .type(InputType.Number).onChange((value: string): void => { this.port = value; })
        TextInput({ text: this.user, placeholder: 'Username' })
          .onChange((value: string): void => { this.user = value; })
        TextInput({ text: this.password, placeholder: 'Password (memory only)' })
          .type(InputType.Password).onChange((value: string): void => { this.password = value; })
        TextInput({ text: this.database, placeholder: 'Database (optional)' })
          .onChange((value: string): void => { this.database = value; })
        TextInput({ text: this.schema, placeholder: 'Authorized acceptance schema' })
          .onChange((value: string): void => { this.schema = value; })
        TextInput({ text: this.caCertPath, placeholder: 'Sandbox-readable CA PEM path (optional)' })
          .onChange((value: string): void => { this.caCertPath = value; })
        TextInput({ text: this.mismatchHost, placeholder: 'Approved TLS mismatch hostname' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.mismatchHost = value; })
        TextInput({ text: this.profile, placeholder: 'PostgreSQL major profile: P15-P18' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.profile = value; })
        TextInput({ text: this.signedHapSha256, placeholder: 'Actual signed/installed HAP SHA-256' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.signedHapSha256 = value; })
        TextInput({ text: this.operatorEvidenceId, placeholder: 'Operator build/sign/install evidence ID' })
          .enabled(this.deviceEvidenceBound)
          .onChange((value: string): void => { this.operatorEvidenceId = value; })
        Button(this.busy ? 'Running...' : 'Run bound device acceptance')
          .enabled(!this.busy && !this.copying && this.deviceEvidenceBound)
          .onClick((): void => { this.runAcceptance(); })
        Button('Copy exact signed receipt JSON')
          .enabled(!this.busy && !this.copying && this.receiptJson.length > 0)
          .onClick((): void => { void this.copyReceipt(); })
        Text(this.output).width('100%').fontFamily('monospace').fontSize(14)
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }
}
