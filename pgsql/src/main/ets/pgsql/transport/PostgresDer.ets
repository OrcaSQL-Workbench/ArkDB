import { ArkDbError } from '@arkdb/core';

const MAXIMUM_DER_ELEMENTS: number = 65536;
const MAXIMUM_DER_DEPTH: number = 32;

export class PostgresDerElement {
  readonly tag: number;
  readonly offset: number;
  readonly start: number;
  readonly end: number;
  readonly next: number;

  constructor(tag: number, offset: number, start: number, end: number) {
    this.tag = tag;
    this.offset = offset;
    this.start = start;
    this.end = end;
    this.next = end;
  }
}

export class PostgresDerReader {
  private readonly data: Uint8Array;
  private readonly maximumDepth: number;
  private validatedElements: number = 0;

  constructor(data: Uint8Array, maximumBytes: number,
    maximumDepth: number) {
    if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1 ||
      !Number.isSafeInteger(maximumDepth) || maximumDepth < 1 ||
      maximumDepth > MAXIMUM_DER_DEPTH || data.length > maximumBytes) {
      throw invalidCertificateIdentity();
    }
    this.data = new Uint8Array(data.length);
    this.data.set(data);
    this.maximumDepth = maximumDepth;
  }

  read(offset: number, limit: number): PostgresDerElement {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(limit) ||
      offset < 0 || limit > this.data.length || offset > limit ||
      offset > limit - 2) {
      throw invalidCertificateIdentity();
    }
    const tag: number = this.data[offset];
    if (tag === 0 || (tag & 0x1f) === 0x1f) {
      throw invalidCertificateIdentity();
    }
    const firstLength: number = this.data[offset + 1];
    let start: number = offset + 2;
    let length: number = firstLength;
    if ((firstLength & 0x80) !== 0) {
      const count: number = firstLength & 0x7f;
      if (count < 1 || count > 4 || start > limit - count ||
        this.data[start] === 0) {
        throw invalidCertificateIdentity();
      }
      length = 0;
      for (let index: number = 0; index < count; index += 1) {
        const next: number = this.data[start + index];
        if (length > Math.floor((Number.MAX_SAFE_INTEGER - next) / 256)) {
          throw invalidCertificateIdentity();
        }
        length = length * 256 + next;
      }
      if (length < 0x80) throw invalidCertificateIdentity();
      start += count;
    }
    if (length > limit - start) throw invalidCertificateIdentity();
    return new PostgresDerElement(tag, offset, start, start + length);
  }

  expected(offset: number, limit: number, tag: number): PostgresDerElement {
    const value: PostgresDerElement = this.read(offset, limit);
    if (value.tag !== tag) throw invalidCertificateIdentity();
    return value;
  }

  validateValue(value: PostgresDerElement, depth: number): void {
    if (!Number.isSafeInteger(depth) || depth < 0) {
      throw invalidCertificateIdentity();
    }
    this.validatedElements = 0;
    this.validateElement(this.canonical(value), depth);
  }

  validBitString(value: PostgresDerElement): boolean {
    value = this.canonical(value);
    if (value.start === value.end) return false;
    const unused: number = this.data[value.start];
    if (unused > 7) return false;
    if (value.end - value.start === 1) return unused === 0;
    if (unused === 0) return true;
    return (this.data[value.end - 1] & ((1 << unused) - 1)) === 0;
  }

  validInteger(value: PostgresDerElement): boolean {
    value = this.canonical(value);
    const length: number = value.end - value.start;
    if (length < 1) return false;
    if (length === 1) return true;
    const first: number = this.data[value.start];
    const second: number = this.data[value.start + 1];
    if (first === 0 && (second & 0x80) === 0) return false;
    return first !== 0xff || (second & 0x80) === 0;
  }

  validOidValue(value: PostgresDerElement): boolean {
    value = this.canonical(value);
    if (value.start === value.end) return false;
    let first: boolean = true;
    for (let index: number = value.start; index < value.end; index += 1) {
      const octet: number = this.data[index];
      if (first && octet === 0x80) return false;
      first = (octet & 0x80) === 0;
    }
    return first;
  }

  validCertificateTime(value: PostgresDerElement): boolean {
    value = this.canonical(value);
    const length: number =
      value.tag === 0x17 ? 13 : value.tag === 0x18 ? 15 : 0;
    if (value.end - value.start !== length ||
      this.data[value.end - 1] !== 0x5a) return false;
    for (let index: number = value.start; index < value.end - 1; index += 1) {
      if (this.data[index] < 0x30 || this.data[index] > 0x39) return false;
    }
    let year: number;
    let offset: number = value.start;
    if (value.tag === 0x17) {
      const shortYear: number = this.decimalPair(offset);
      year = shortYear >= 50 ? shortYear + 1900 : shortYear + 2000;
      offset += 2;
    } else {
      year = this.decimalPair(offset) * 100 + this.decimalPair(offset + 2);
      offset += 4;
    }
    const month: number = this.decimalPair(offset);
    const day: number = this.decimalPair(offset + 2);
    const hour: number = this.decimalPair(offset + 4);
    const minute: number = this.decimalPair(offset + 6);
    const second: number = this.decimalPair(offset + 8);
    if (month < 1 || month > 12 || hour > 23 ||
      minute > 59 || second > 59) return false;
    let maximumDay: number = 31;
    if (month === 4 || month === 6 || month === 9 || month === 11) {
      maximumDay = 30;
    } else if (month === 2) {
      const leap: boolean = year % 4 === 0 &&
        (year % 100 !== 0 || year % 400 === 0);
      maximumDay = leap ? 29 : 28;
    }
    return day >= 1 && day <= maximumDay;
  }

  compare(leftStart: number, leftEnd: number,
    rightStart: number, rightEnd: number): number {
    this.requireRange(leftStart, leftEnd);
    this.requireRange(rightStart, rightEnd);
    const length: number = Math.min(
      leftEnd - leftStart, rightEnd - rightStart);
    for (let index: number = 0; index < length; index += 1) {
      const difference: number =
        this.data[leftStart + index] - this.data[rightStart + index];
      if (difference !== 0) return difference;
    }
    return leftEnd - leftStart - (rightEnd - rightStart);
  }

  copy(start: number, end: number): Uint8Array {
    this.requireRange(start, end);
    const result = new Uint8Array(end - start);
    result.set(this.data.subarray(start, end));
    return result;
  }

  private validateElement(value: PostgresDerElement, depth: number): void {
    this.validatedElements += 1;
    if (this.validatedElements > MAXIMUM_DER_ELEMENTS ||
      value.offset < 0 || value.start < value.offset + 2 ||
      value.end < value.start || value.next !== value.end ||
      value.end > this.data.length) {
      throw invalidCertificateIdentity();
    }
    if ((value.tag & 0x20) === 0) {
      if (!this.validPrimitiveValue(value)) {
        throw invalidCertificateIdentity();
      }
      return;
    }
    if ((value.tag & 0xc0) === 0 &&
      value.tag !== 0x30 && value.tag !== 0x31) {
      throw invalidCertificateIdentity();
    }
    if (depth >= this.maximumDepth) throw invalidCertificateIdentity();
    let offset: number = value.start;
    while (offset < value.end) {
      const child: PostgresDerElement = this.read(offset, value.end);
      this.validateElement(child, depth + 1);
      offset = child.next;
    }
  }

  private validPrimitiveValue(value: PostgresDerElement): boolean {
    if ((value.tag & 0xc0) !== 0) return true;
    const length: number = value.end - value.start;
    if (value.tag === 0x01) {
      return length === 1 &&
        (this.data[value.start] === 0 || this.data[value.start] === 0xff);
    }
    if (value.tag === 0x02 || value.tag === 0x0a) {
      return this.validInteger(value);
    }
    if (value.tag === 0x03) return this.validBitString(value);
    if (value.tag === 0x04) return true;
    if (value.tag === 0x05) return length === 0;
    if (value.tag === 0x06) return this.validOidValue(value);
    if (value.tag === 0x0c) return this.validUtf8(value.start, value.end);
    if (value.tag === 0x12) {
      return this.validAsciiSet(value.start, value.end, ' 0123456789');
    }
    if (value.tag === 0x13) {
      return this.validAsciiSet(value.start, value.end,
        " '()+,-./0123456789:=?ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz");
    }
    if (value.tag === 0x14) return this.validTeletex(value);
    if (value.tag === 0x16) {
      for (let index: number = value.start; index < value.end; index += 1) {
        if (this.data[index] > 0x7f) return false;
      }
      return true;
    }
    if (value.tag === 0x17 || value.tag === 0x18) {
      return this.validCertificateTime(value);
    }
    if (value.tag === 0x1c) return this.validUniversalString(value);
    if (value.tag === 0x1e) return this.validBmpString(value);
    return false;
  }

  private validAsciiSet(start: number, end: number,
    allowed: string): boolean {
    for (let index: number = start; index < end; index += 1) {
      if (allowed.indexOf(String.fromCharCode(this.data[index])) < 0) {
        return false;
      }
    }
    return true;
  }

  private validUtf8(start: number, end: number): boolean {
    let index: number = start;
    while (index < end) {
      const first: number = this.data[index];
      if (first <= 0x7f) {
        index += 1;
        continue;
      }
      let count: number;
      let minimum: number;
      let code: number;
      if (first >= 0xc2 && first <= 0xdf) {
        count = 1; minimum = 0x80; code = first & 0x1f;
      } else if (first >= 0xe0 && first <= 0xef) {
        count = 2; minimum = 0x800; code = first & 0x0f;
      } else if (first >= 0xf0 && first <= 0xf4) {
        count = 3; minimum = 0x10000; code = first & 0x07;
      } else {
        return false;
      }
      if (index + count >= end) return false;
      for (let offset: number = 1; offset <= count; offset += 1) {
        const next: number = this.data[index + offset];
        if ((next & 0xc0) !== 0x80) return false;
        code = (code << 6) | (next & 0x3f);
      }
      if (code < minimum || code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) return false;
      index += count + 1;
    }
    return true;
  }

  private validTeletex(value: PostgresDerElement): boolean {
    let g0: number = 102;
    let index: number = value.start;
    while (index < value.end) {
      const octet: number = this.data[index];
      if (octet === 0x1b) {
        if (index > value.end - 3) return false;
        const intermediate: number = this.data[index + 1];
        const finalOctet: number = this.data[index + 2];
        // X.690 8.23.5.1-.4 and 11.4; ISO-IR 102/103/106/107;
        // T.61 4.1.2-.3 and Annex A-B. This subset accepts those core
        // graphics/designations and rejects all other sets, shifts and controls.
        if (intermediate === 0x28 && finalOctet === 0x75) {
          g0 = 102;
        } else if (intermediate === 0x28 && finalOctet === 0x76) {
          g0 = 103;
        } else if (!((intermediate === 0x21 && finalOctet === 0x45) ||
          (intermediate === 0x22 && finalOctet === 0x48))) {
          return false;
        }
        index += 3;
        continue;
      }
      if (octet === 0x20) {
        index += 1;
        continue;
      }
      if (octet < 0x80) {
        if (g0 === 102) {
          if (!this.validTeletexPrimary(octet)) return false;
        } else {
          const supplementary: number = octet + 0x80;
          if (!this.validTeletexSupplementary(supplementary) ||
            this.teletexDiacritic(supplementary)) return false;
        }
        index += 1;
        continue;
      }
      if (!this.validTeletexSupplementary(octet)) return false;
      if (this.teletexDiacritic(octet)) {
        if (g0 !== 102 || index + 1 >= value.end) return false;
        const next: number = this.data[index + 1];
        if (!this.validTeletexCombination(octet, next)) return false;
        index += 2;
      } else {
        index += 1;
      }
    }
    return true;
  }

  private validTeletexPrimary(octet: number): boolean {
    return (octet >= 0x21 && octet <= 0x5b) ||
      octet === 0x5d || octet === 0x5f ||
      (octet >= 0x61 && octet <= 0x7a) || octet === 0x7c;
  }

  private validTeletexSupplementary(octet: number): boolean {
    return (octet >= 0xa1 && octet <= 0xa8) || octet === 0xaa ||
      (octet >= 0xb0 && octet <= 0xb8) ||
      (octet >= 0xbb && octet <= 0xbf) ||
      (octet >= 0xc1 && octet <= 0xc8) ||
      (octet >= 0xca && octet <= 0xcb) ||
      (octet >= 0xcd && octet <= 0xcf) ||
      (octet >= 0xe0 && octet <= 0xe4) ||
      (octet >= 0xe6 && octet <= 0xe8) ||
      (octet >= 0xea && octet <= 0xfe);
  }

  private teletexDiacritic(octet: number): boolean {
    return (octet >= 0xc1 && octet <= 0xc8) ||
      (octet >= 0xca && octet <= 0xcb) ||
      (octet >= 0xcd && octet <= 0xcf);
  }

  private validTeletexCombination(mark: number, value: number): boolean {
    if (value === 0x20) return true;
    if ((mark === 0xc2 && value === 0x47) ||
      (mark === 0xc7 && value === 0x69) ||
      (mark === 0xcb && value === 0x67)) return false;
    const letter: number =
      value >= 0x61 && value <= 0x7a ? value - 0x20 : value;
    let allowed: string = '';
    if (mark === 0xc1) allowed = 'AEIOU';
    else if (mark === 0xc2) allowed = 'ACEGILNORSUYZ';
    else if (mark === 0xc3) allowed = 'ACEGHIJOSUWY';
    else if (mark === 0xc4) allowed = 'AINOU';
    else if (mark === 0xc5) allowed = 'AEIOU';
    else if (mark === 0xc6) allowed = 'AGU';
    else if (mark === 0xc7) allowed = 'CEGIZ';
    else if (mark === 0xc8) allowed = 'AEIOUY';
    else if (mark === 0xca) allowed = 'AU';
    else if (mark === 0xcb) allowed = 'CGKLNRST';
    else if (mark === 0xcd) allowed = 'OU';
    else if (mark === 0xce) allowed = 'AEIU';
    else if (mark === 0xcf) allowed = 'CDELNRSTZ';
    return allowed.indexOf(String.fromCharCode(letter)) >= 0;
  }

  private validUniversalString(value: PostgresDerElement): boolean {
    if ((value.end - value.start) % 4 !== 0) return false;
    for (let index: number = value.start; index < value.end; index += 4) {
      const code: number = this.data[index] * 0x1000000 +
        this.data[index + 1] * 0x10000 +
        this.data[index + 2] * 0x100 + this.data[index + 3];
      if (code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) return false;
    }
    return true;
  }

  private validBmpString(value: PostgresDerElement): boolean {
    if ((value.end - value.start) % 2 !== 0) return false;
    for (let index: number = value.start; index < value.end; index += 2) {
      const code: number =
        this.data[index] * 256 + this.data[index + 1];
      if (code >= 0xd800 && code <= 0xdfff) return false;
    }
    return true;
  }

  private decimalPair(offset: number): number {
    return (this.data[offset] - 0x30) * 10 +
      this.data[offset + 1] - 0x30;
  }

  private canonical(value: PostgresDerElement): PostgresDerElement {
    const actual: PostgresDerElement = this.read(value.offset, value.next);
    if (actual.tag !== value.tag || actual.start !== value.start ||
      actual.end !== value.end) throw invalidCertificateIdentity();
    return actual;
  }

  private requireRange(start: number, end: number): void {
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || end < start || end > this.data.length) {
      throw invalidCertificateIdentity();
    }
  }
}

function invalidCertificateIdentity(): ArkDbError {
  return ArkDbError.tls(
    'Invalid PostgreSQL TLS certificate identity',
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}
