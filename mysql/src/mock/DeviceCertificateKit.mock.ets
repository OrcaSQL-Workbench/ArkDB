import { cert as platformCert } from '@kit.DeviceCertificateKit';

class MockDistinguishedName {
  private commonNames: string[];

  constructor(commonNames: string[]) {
    this.commonNames = commonNames;
  }

  getName(name: string): string[] {
    if (name !== 'CN') throw new Error('Unsupported certificate fixture name');
    return this.commonNames;
  }
}

/** Controlled decoded identity data, not certificate parsing or chain validation. */
export class MockX509Cert {
  dnsNames: Uint8Array[] = [];
  ipNames: Uint8Array[] = [];
  commonNames: string[] = [];
  missingSubjectAltNames: boolean = false;

  getSubjectAltNames(): platformCert.DataArray {
    if (this.missingSubjectAltNames) throw new Error('Synthetic certificate has no subject alternative names');
    const names: platformCert.DataArray = { data: this.dnsNames };
    return names;
  }

  getSubjectX500DistinguishedName(): MockDistinguishedName {
    return new MockDistinguishedName(this.commonNames);
  }

  match(parameters: platformCert.X509CertMatchParameters): boolean {
    const names = parameters.subjectAlternativeNames;
    if (names === undefined || names.length !== 1 ||
      parameters.matchAllSubjectAltNames !== false ||
      names[0].type !== platformCert.GeneralNameType.GENERAL_NAME_TYPE_IP_ADDRESS) return false;
    const expected = names[0].name;
    if (expected === undefined) return false;
    for (const ip of this.ipNames) {
      if (ip.length === expected.length &&
        ip.every((value: number, index: number): boolean => value === expected[index])) return true;
    }
    return false;
  }
}

export namespace cert {
  export enum EncodingFormat {
    FORMAT_DER = 0
  }

  export enum GeneralNameType {
    GENERAL_NAME_TYPE_IP_ADDRESS = 7
  }

  export let nextCertificate: MockX509Cert | null = null;
  export let createCalls: number = 0;

  export function createX509Cert(encoded: platformCert.EncodingBlob): Promise<MockX509Cert> {
    createCalls += 1;
    const certificate = nextCertificate;
    nextCertificate = null;
    if (certificate === null || encoded.encodingFormat !== platformCert.EncodingFormat.FORMAT_DER ||
      encoded.data.length !== 2 || encoded.data[0] !== 0x30 || encoded.data[1] !== 0) {
      return Promise.reject(new Error('Unsupported synthetic certificate fixture'));
    }
    return Promise.resolve(certificate);
  }
}

export default cert;
