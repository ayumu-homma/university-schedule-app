import {
  type EmailProviderConnector,
  type ProviderFetchPage,
  type ProviderFetchRequest,
  SafeEmailError,
} from "../types.ts";

/** Test-only scripted connector. Production code never imports this module. */
export class FakeEmailConnector implements EmailProviderConnector {
  readonly provider = "gmail" as const;
  readonly requests: ProviderFetchRequest[] = [];
  readonly #steps: Array<ProviderFetchPage | SafeEmailError>;

  constructor(steps: readonly (ProviderFetchPage | SafeEmailError)[]) {
    this.#steps = [...steps];
  }

  fetchPage(request: ProviderFetchRequest): Promise<ProviderFetchPage> {
    this.requests.push({ ...request });
    const step = this.#steps.shift();
    if (step === undefined) {
      return Promise.reject(new SafeEmailError("provider_unavailable"));
    }
    return step instanceof SafeEmailError
      ? Promise.reject(step)
      : Promise.resolve(step);
  }
}
