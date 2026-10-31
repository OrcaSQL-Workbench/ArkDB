export interface MySqlSessionController {
  reset(): Promise<void>;
}

export class MySqlConnectionSessionController implements MySqlSessionController {
  private resetSession: () => Promise<void>;

  constructor(resetSession: () => Promise<void>) {
    this.resetSession = resetSession;
  }

  reset(): Promise<void> {
    return this.resetSession();
  }
}
