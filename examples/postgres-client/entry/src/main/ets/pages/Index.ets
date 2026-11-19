import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import { SampleRequest, SampleResponse } from '../sample/Messages';

@Entry
@Component
struct Index {
  @State host: string = '';
  @State port: string = '5432';
  @State user: string = '';
  @State password: string = '';
  @State database: string = '';
  @State schema: string = '';
  @State caCertPath: string = '';
  @State status: string = 'Idle. Enter connection details to run the read-only TLS sample.';
  @State running: boolean = false;
  @State stopping: boolean = false;
  private activeWorker: worker.ThreadWorker | null = null;
  private activeRequest: SampleRequest | null = null;
  private stoppingWorker: worker.ThreadWorker | null = null;
  private stopTimer: number = -1;
  aboutToDisappear(): void { this.stopCurrentRun(true); }
  build() {
    Column({ space: 8 }) {
      Text('ArkDB PostgreSQL Example').fontSize(20).fontWeight(FontWeight.Bold)
      Text('Runs one read-only VERIFY_FULL TLS streaming query inside an ArkTS Worker.')
        .fontSize(12).fontColor('#555555')
      TextInput({ placeholder: 'PostgreSQL host (hostname or IP matching cert SAN/CN)', text: this.host })
        .onChange((v: string): void => { this.host = v; })
      TextInput({ placeholder: 'Port', text: this.port }).type(InputType.Number).onChange((v: string): void => { this.port = v; })
      TextInput({ placeholder: 'User', text: this.user }).onChange((v: string): void => { this.user = v; })
      TextInput({ placeholder: 'Password (cleared after submit)', text: this.password })
        .type(InputType.Password).onChange((v: string): void => { this.password = v; })
      TextInput({ placeholder: 'Database (optional)', text: this.database }).onChange((v: string): void => { this.database = v; })
      TextInput({ placeholder: 'Schema (optional)', text: this.schema }).onChange((v: string): void => { this.schema = v; })
      TextInput({ placeholder: 'CA certificate PEM path in app sandbox (optional)', text: this.caCertPath })
        .onChange((v: string): void => { this.caCertPath = v; })
      Row({ space: 8 }) {
        Button(this.running ? 'Running...' : 'Run Read-Only TLS Sample').enabled(!this.running).onClick((): void => { this.run(); })
        Button(this.stopping ? 'Stopping...' : 'Stop').enabled(this.running && !this.stopping)
          .onClick((): void => { this.stopCurrentRun(false); })
      }
      Scroll() { Text(this.status).fontSize(12).width('100%') }.layoutWeight(1).width('100%')
    }.padding(16).width('100%').height('100%')
  }

  private run(): void {
    if (this.running) return;
    const request = new SampleRequest();
    request.host = this.host.trim();
    const parsedPort = Number(this.port.trim());
    request.port = this.port.trim().length > 0 && Number.isFinite(parsedPort) ? parsedPort : Number.NaN;
    request.user = this.user.trim();
    request.password = this.password;
    this.password = '';
    request.database = this.database.trim();
    request.schema = this.schema.trim();
    request.caCertPath = this.caCertPath.trim();
    this.running = true;
    this.stopping = false;
    this.status = 'Connecting on Worker with VERIFY_FULL TLS...';
    let responseStatus: string = '';
    let sampleWorker: worker.ThreadWorker;
    try {
      sampleWorker = new worker.ThreadWorker('entry/ets/workers/postgres.worker.ets');
    } catch {
      request.password = '';
      this.running = false;
      this.status = 'Failed to start Worker. No request was sent.';
      return;
    }
    this.activeWorker = sampleWorker;
    this.activeRequest = request;
    sampleWorker.onmessage = (event: MessageEvents): void => {
      const data = event.data as Object;
      const terminate = !(data instanceof SampleResponse) || data.requiresTermination;
      const msg = data instanceof SampleResponse && this.stopping && data.errorKind === 'cancelled'
        ? 'Sample stopped. Outcome is unknown; SQL was not replayed.\n' + data.text
        : data instanceof SampleResponse ? (data.ok ? 'Success:\n' : 'Error (' + data.errorKind + '):\n') + data.text
          : 'Worker returned an unexpected response.';
      responseStatus = msg;
      this.finishWorker(sampleWorker, msg, terminate, request, true);
    };
    sampleWorker.onerror = (_e: ErrorEvent): void => {
      this.finishWorker(sampleWorker, responseStatus.length > 0 ? responseStatus : 'Worker failed with unknown query outcome. SQL was not replayed.', true, request, true);
    };
    sampleWorker.onmessageerror = (_e: MessageEvents): void => {
      this.finishWorker(sampleWorker, responseStatus.length > 0 ? responseStatus : 'Worker message serialization failed. SQL was not replayed.', true, request, true);
    };
    sampleWorker.onexit = (_code: number): void => {
      const exitStatus = this.status.startsWith('Connecting on Worker')
        ? 'Worker exited before returning a response. Outcome is unknown; SQL was not replayed.'
        : this.status;
      this.finishWorker(sampleWorker, exitStatus, false, request, true);
    };
    try {
      sampleWorker.postMessageWithSharedSendable(request);
    } catch {
      this.scrubRequest(request);
      this.finishWorker(sampleWorker, 'Failed to dispatch request to Worker. SQL was not replayed.', true, request);
    }
  }
  private finishWorker(
    target: worker.ThreadWorker, status: string, terminate: boolean,
    request: SampleRequest | null, scrub: boolean = false
  ): void {
    if (!terminate && this.stoppingWorker === target && this.stopTimer !== -1) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
      this.stoppingWorker = null;
    }
    if (this.activeWorker === target) this.status = status;
    if (terminate) {
      if (request !== null) this.scrubRequest(request);
      try { target.terminate(); } catch {
        this.stopping = false;
        this.status += '\nWorker termination could not be confirmed; waiting for Worker exit.';
      }
      return;
    }
    if (scrub && request !== null) this.scrubRequest(request);
    this.clearWorker(target);
  }
  private stopCurrentRun(leavingPage: boolean): void {
    this.password = '';
    const runningWorker = this.activeWorker;
    if (runningWorker === null) return;
    if (!leavingPage) {
      if (this.stopping) return;
      this.stopping = true;
      this.status = 'Stopping sample... Outcome may be unknown; SQL is not replayed.';
    }
    const stopRequest = new SampleRequest();
    stopRequest.operation = 'stop';
    const activeRequest = this.activeRequest;
    try {
      runningWorker.postMessageWithSharedSendable(stopRequest);
      if (this.stopTimer !== -1) clearTimeout(this.stopTimer);
      this.stoppingWorker = runningWorker;
      const request = activeRequest;
      this.stopTimer = setTimeout((): void => {
        if (this.activeWorker !== runningWorker) return;
        const timeoutStatus = this.status.startsWith('Stopping sample...')
          ? 'Sample stopped before Worker finished. Outcome is unknown; SQL was not replayed.'
          : this.status;
        this.finishWorker(runningWorker, timeoutStatus, true, request);
      }, 2000);
    } catch {
      if (this.activeWorker === runningWorker && !leavingPage) {
        this.status = 'Sample stopped. Outcome is unknown; SQL was not replayed.';
      }
      this.finishWorker(runningWorker, 'Sample stopped. Outcome is unknown; SQL was not replayed.',
        true, activeRequest);
    }
  }
  private clearWorker(target: worker.ThreadWorker): void {
    if (this.activeWorker === target) {
      this.activeWorker = null;
      this.running = false;
      this.stopping = false;
    }
  }

  private scrubRequest(request: SampleRequest): void {
    request.password = '';
    if (this.activeRequest === request) this.activeRequest = null;
  }
}
