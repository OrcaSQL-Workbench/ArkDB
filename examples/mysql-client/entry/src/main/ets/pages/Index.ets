import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import { SampleRequest, SampleResponse } from '../sample/Messages';

@Entry
@Component
struct Index {
  @State private host: string = '';
  @State private port: string = '3306';
  @State private user: string = '';
  @State private password: string = '';
  @State private schema: string = '';
  @State private caCertPath: string = '';
  @State private busy: boolean = false;
  @State private output: string = 'Enter an isolated test-server account, then run the fixed read-only query.';
  private instance: worker.ThreadWorker | null = null;
  private stopTimer: number = -1;
  private receivedResponse: boolean = false;

  aboutToDisappear(): void {
    this.password = '';
    const instance = this.instance;
    if (instance === null) return;
    const stop = new SampleRequest();
    stop.operation = 'stop';
    try {
      instance.postMessage(stop);
    } catch (error) {
      console.error('ArkDB example could not deliver graceful shutdown.');
    }
    this.stopTimer = setTimeout((): void => {
      if (this.instance === instance) {
        console.error('ArkDB example forced Worker shutdown; execution outcome is not assumed.');
        this.terminate(instance);
      }
    }, 2000);
  }

  private run(): void {
    if (this.busy || this.instance !== null) return;
    const request = new SampleRequest();
    request.host = this.host.trim();
    request.port = Number(this.port);
    request.user = this.user;
    request.password = this.password;
    request.schema = this.schema;
    request.caCertPath = this.caCertPath.trim();
    this.password = '';
    this.busy = true;
    this.receivedResponse = false;
    this.output = 'Connecting in a Worker with TLS hostname verification...';
    try {
      const instance = new worker.ThreadWorker('entry/ets/workers/mysql.worker.ets');
      this.instance = instance;
      instance.onmessage = (event: MessageEvents): void => {
        this.receivedResponse = true;
        const response: Object = event.data;
        if (!(response instanceof SampleResponse)) {
          this.output = 'Invalid Worker response. No SQL was replayed.';
        } else {
          this.output = (response.ok ? 'Completed\n' : 'Failed\n') + response.text;
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
      this.output = 'Could not start the Worker. Check the sample Worker build configuration.';
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
      console.error('ArkDB example Worker cleanup failed.');
    }
    this.busy = false;
    this.instance = null;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('ArkDB MySQL example').fontSize(26).fontWeight(FontWeight.Bold)
        Text('Fixed read-only query. TLS identity verification is always enabled.')
        TextInput({ text: this.host, placeholder: 'Server hostname' })
          .onChange((value: string): void => { this.host = value; })
        TextInput({ text: this.port, placeholder: 'Port' })
          .type(InputType.Number).onChange((value: string): void => { this.port = value; })
        TextInput({ text: this.user, placeholder: 'Username' })
          .onChange((value: string): void => { this.user = value; })
        TextInput({ text: this.password, placeholder: 'Password (memory only)' })
          .type(InputType.Password).onChange((value: string): void => { this.password = value; })
        TextInput({ text: this.schema, placeholder: 'Default database (optional)' })
          .onChange((value: string): void => { this.schema = value; })
        TextInput({ text: this.caCertPath, placeholder: 'Sandbox-readable CA PEM path (optional)' })
          .onChange((value: string): void => { this.caCertPath = value; })
        Button(this.busy ? 'Running...' : 'Connect, read, and close')
          .enabled(!this.busy)
          .onClick((): void => { this.run(); })
        Text(this.output).width('100%').fontFamily('monospace').fontSize(14)
      }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%')
  }
}
