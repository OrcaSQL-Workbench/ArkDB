import { ArkDbError } from '@arkdb/core';
import {
  PostgresDerElement, PostgresDerReader
} from './PostgresDer';

const MAX_POSTGRES_CERTIFICATE_DER_BYTES: number = 1024 * 1024;
const MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES: number = 64 * 1024;
const MAX_POSTGRES_CERTIFICATE_EXTENSIONS: number = 256;
const MAX_POSTGRES_GENERAL_NAMES: number = 256;
const MAX_POSTGRES_DNS_NAME_BYTES: number = 253;
const MAX_POSTGRES_DER_NESTING: number = 32;

export interface PostgresCertificateStructure {
  extensions: Uint8Array | null;
}

export interface PostgresCertificateSubjectAlternativeName {
  present: boolean;
  entryValue: Uint8Array | null;
}

export interface PostgresSubjectAlternativeNames {
  dnsNames: Uint8Array[];
  ipAddresses: Uint8Array[];
  otherGeneralNameTags: number[];
}

export function postgresParseCertificateStructure(
  certificateDer: Uint8Array): PostgresCertificateStructure {
  const reader = new PostgresDerReader(
    certificateDer, MAX_POSTGRES_CERTIFICATE_DER_BYTES,
    MAX_POSTGRES_DER_NESTING);
  const certificate = reader.expected(0, certificateDer.length, 0x30);
  if (certificate.next !== certificateDer.length) {
    throw invalidCertificateIdentity();
  }
  let offset = certificate.start;
  const tbsCertificate = reader.expected(offset, certificate.end, 0x30);
  offset = tbsCertificate.next;
  const signatureAlgorithm =
    reader.expected(offset, certificate.end, 0x30);
  validateAlgorithmIdentifier(reader, signatureAlgorithm);
  offset = signatureAlgorithm.next;
  const signatureValue = reader.expected(offset, certificate.end, 0x03);
  if (signatureValue.end - signatureValue.start < 2 ||
    !reader.validBitString(signatureValue) ||
    signatureValue.next !== certificate.end) {
    throw invalidCertificateIdentity();
  }
  return tbsCertificateStructure(
    reader, tbsCertificate, signatureAlgorithm);
}

export function postgresParseCertificateSubjectAlternativeName(
  certificateDer: Uint8Array): PostgresCertificateSubjectAlternativeName {
  const certificate = postgresParseCertificateStructure(certificateDer);
  if (certificate.extensions === null) {
    return { present: false, entryValue: null };
  }
  return extensionsSubjectAlternativeName(certificate.extensions);
}

export function postgresParseSubjectAlternativeNamesEntry(
  entryValue: Uint8Array): PostgresSubjectAlternativeNames {
  const reader = new PostgresDerReader(
    entryValue, MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES,
    MAX_POSTGRES_DER_NESTING);
  const outer = reader.expected(0, entryValue.length, 0x04);
  if (outer.next !== entryValue.length) throw invalidCertificateIdentity();
  const names = reader.expected(outer.start, outer.end, 0x30);
  if (names.next !== outer.end || names.start === names.end) {
    throw invalidCertificateIdentity();
  }
  const result: PostgresSubjectAlternativeNames = {
    dnsNames: [], ipAddresses: [], otherGeneralNameTags: []
  };
  let offset = names.start;
  let count = 0;
  while (offset < names.end) {
    if (count >= MAX_POSTGRES_GENERAL_NAMES) {
      throw invalidCertificateIdentity();
    }
    count += 1;
    const name = reader.read(offset, names.end);
    if (name.tag === 0x82) {
      result.dnsNames.push(copyIa5GeneralName(
        reader, name, MAX_POSTGRES_DNS_NAME_BYTES));
    } else if (name.tag === 0x87) {
      const length = name.end - name.start;
      if (length !== 4 && length !== 16) {
        throw invalidCertificateIdentity();
      }
      result.ipAddresses.push(reader.copy(name.start, name.end));
    } else {
      validateOtherGeneralName(reader, name);
      result.otherGeneralNameTags.push(name.tag);
    }
    offset = name.next;
  }
  return result;
}

function validateOtherGeneralName(reader: PostgresDerReader,
  name: PostgresDerElement): void {
  if (name.tag === 0x81 || name.tag === 0x86) {
    copyIa5GeneralName(
      reader, name, MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES);
    return;
  }
  if (name.tag === 0x88) {
    if (!reader.validOidValue(name)) throw invalidCertificateIdentity();
    return;
  }
  if (name.tag === 0xa0) {
    validateOtherName(reader, name);
    return;
  }
  if (name.tag === 0xa4) {
    validateDirectoryName(reader, name);
    return;
  }
  if (name.tag === 0xa5) {
    validateEdiPartyName(reader, name);
    return;
  }
  throw invalidCertificateIdentity();
}

function copyIa5GeneralName(reader: PostgresDerReader,
  name: PostgresDerElement, maximumBytes: number): Uint8Array {
  const value = reader.copy(name.start, name.end);
  if (value.length < 1 || value.length > maximumBytes) {
    throw invalidCertificateIdentity();
  }
  for (let index = 0; index < value.length; index += 1) {
    if (value[index] > 0x7f) throw invalidCertificateIdentity();
  }
  return value;
}

function validateOtherName(reader: PostgresDerReader,
  name: PostgresDerElement): void {
  const oid = reader.expected(name.start, name.end, 0x06);
  if (!reader.validOidValue(oid)) throw invalidCertificateIdentity();
  const value = reader.expected(oid.next, name.end, 0xa0);
  if (value.next !== name.end) throw invalidCertificateIdentity();
  const encoded = reader.read(value.start, value.end);
  if (encoded.next !== value.end) throw invalidCertificateIdentity();
  reader.validateValue(encoded, 0);
  validateCanonicalSets(reader, encoded, 0);
}

function validateCanonicalSets(reader: PostgresDerReader,
  value: PostgresDerElement, depth: number): void {
  if ((value.tag & 0x20) === 0) return;
  if (depth >= MAX_POSTGRES_DER_NESTING) {
    throw invalidCertificateIdentity();
  }
  let offset = value.start;
  let previous: PostgresDerElement | null = null;
  while (offset < value.end) {
    const child = reader.read(offset, value.end);
    if (value.tag === 0x31 && previous !== null &&
      compareCanonicalSetElements(reader, previous, child) > 0) {
      throw invalidCertificateIdentity();
    }
    validateCanonicalSets(reader, child, depth + 1);
    previous = child;
    offset = child.next;
  }
}

function compareCanonicalSetElements(reader: PostgresDerReader,
  left: PostgresDerElement, right: PostgresDerElement): number {
  const leftTag = left.tag & 0xdf;
  const rightTag = right.tag & 0xdf;
  if (leftTag !== rightTag) return leftTag - rightTag;
  return reader.compare(left.offset, left.next, right.offset, right.next);
}

function validateDirectoryName(reader: PostgresDerReader,
  name: PostgresDerElement): void {
  const value = reader.expected(name.start, name.end, 0x30);
  if (value.next !== name.end) throw invalidCertificateIdentity();
  validateName(reader, value, false);
}

function validateEdiPartyName(reader: PostgresDerReader,
  name: PostgresDerElement): void {
  let value = reader.read(name.start, name.end);
  if (value.tag === 0xa0) {
    validateDirectoryString(reader, value);
    value = reader.read(value.next, name.end);
  }
  if (value.tag !== 0xa1 || value.next !== name.end) {
    throw invalidCertificateIdentity();
  }
  validateDirectoryString(reader, value);
}

function validateDirectoryString(reader: PostgresDerReader,
  value: PostgresDerElement): void {
  const string = reader.read(value.start, value.end);
  if (string.next !== value.end || string.start === string.end ||
    (string.tag !== 0x0c && string.tag !== 0x13 &&
      string.tag !== 0x1c && string.tag !== 0x1e)) {
    throw invalidCertificateIdentity();
  }
  reader.validateValue(string, 0);
}

function extensionsSubjectAlternativeName(
  extensionsDer: Uint8Array): PostgresCertificateSubjectAlternativeName {
  const reader = new PostgresDerReader(
    extensionsDer, MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES + 5,
    MAX_POSTGRES_DER_NESTING);
  const extensions = reader.expected(0, extensionsDer.length, 0x30);
  if (extensions.next !== extensionsDer.length ||
    extensions.end - extensions.start >
      MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES) {
    throw invalidCertificateIdentity();
  }
  let offset = extensions.start;
  let entryValue: Uint8Array | null = null;
  let count = 0;
  while (offset < extensions.end) {
    if (count >= MAX_POSTGRES_CERTIFICATE_EXTENSIONS) {
      throw invalidCertificateIdentity();
    }
    count += 1;
    const extension = reader.expected(offset, extensions.end, 0x30);
    let child = reader.expected(extension.start, extension.end, 0x06);
    if (!reader.validOidValue(child)) throw invalidCertificateIdentity();
    const isSubjectAlternativeName =
      oidEquals(reader, child, [0x55, 0x1d, 0x11]);
    let childOffset = child.next;
    child = reader.read(childOffset, extension.end);
    if (child.tag === 0x01) {
      const critical = reader.copy(child.start, child.end);
      if (critical.length !== 1 || critical[0] !== 0xff) {
        throw invalidCertificateIdentity();
      }
      childOffset = child.next;
      child = reader.read(childOffset, extension.end);
    }
    if (child.tag !== 0x04 || child.next !== extension.end) {
      throw invalidCertificateIdentity();
    }
    if (isSubjectAlternativeName) {
      if (entryValue !== null) throw invalidCertificateIdentity();
      entryValue = reader.copy(childOffset, child.next);
    }
    offset = extension.next;
  }
  return {
    present: entryValue !== null,
    entryValue: entryValue
  };
}

function oidEquals(reader: PostgresDerReader,
  oid: PostgresDerElement, expected: number[]): boolean {
  const value = reader.copy(oid.start, oid.end);
  if (value.length !== expected.length) return false;
  for (let index = 0; index < expected.length; index += 1) {
    if (value[index] !== expected[index]) return false;
  }
  return true;
}

function tbsCertificateStructure(reader: PostgresDerReader,
  tbsCertificate: PostgresDerElement,
  certificateSignature: PostgresDerElement): PostgresCertificateStructure {
  let offset = tbsCertificate.start;
  let version = 0;
  let field = reader.read(offset, tbsCertificate.end);
  if (field.tag === 0xa0) {
    const versionElement = reader.expected(field.start, field.end, 0x02);
    if (versionElement.next !== field.end ||
      !reader.validInteger(versionElement) ||
      versionElement.end - versionElement.start !== 1) {
      throw invalidCertificateIdentity();
    }
    version = reader.copy(
      versionElement.start, versionElement.end)[0];
    if (version < 1 || version > 2) throw invalidCertificateIdentity();
    offset = field.next;
  }
  const serialNumber = reader.expected(offset, tbsCertificate.end, 0x02);
  if (!reader.validInteger(serialNumber)) {
    throw invalidCertificateIdentity();
  }
  offset = serialNumber.next;
  const signature = reader.expected(offset, tbsCertificate.end, 0x30);
  validateAlgorithmIdentifier(reader, signature);
  if (reader.compare(signature.offset, signature.next,
    certificateSignature.offset, certificateSignature.next) !== 0) {
    throw invalidCertificateIdentity();
  }
  offset = signature.next;
  const issuer = reader.expected(offset, tbsCertificate.end, 0x30);
  validateName(reader, issuer, false);
  offset = issuer.next;
  const validity = reader.expected(offset, tbsCertificate.end, 0x30);
  validateValidity(reader, validity);
  offset = validity.next;
  const subject = reader.expected(offset, tbsCertificate.end, 0x30);
  validateName(reader, subject, true);
  offset = subject.next;
  const subjectPublicKeyInfo =
    reader.expected(offset, tbsCertificate.end, 0x30);
  validateSubjectPublicKeyInfo(reader, subjectPublicKeyInfo);
  offset = subjectPublicKeyInfo.next;
  if (offset === tbsCertificate.end) return { extensions: null };
  field = reader.read(offset, tbsCertificate.end);
  if (field.tag === 0x81) {
    if (version === 0 || !reader.validBitString(field)) {
      throw invalidCertificateIdentity();
    }
    offset = field.next;
    if (offset === tbsCertificate.end) return { extensions: null };
    field = reader.read(offset, tbsCertificate.end);
  }
  if (field.tag === 0x82) {
    if (version === 0 || !reader.validBitString(field)) {
      throw invalidCertificateIdentity();
    }
    offset = field.next;
    if (offset === tbsCertificate.end) return { extensions: null };
    field = reader.read(offset, tbsCertificate.end);
  }
  if (version !== 2 || field.tag !== 0xa3 ||
    field.next !== tbsCertificate.end) {
    throw invalidCertificateIdentity();
  }
  const extensions = reader.expected(field.start, field.end, 0x30);
  if (extensions.next !== field.end ||
    extensions.start === extensions.end ||
    extensions.end - extensions.start >
      MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES) {
    throw invalidCertificateIdentity();
  }
  return {
    extensions: reader.copy(extensions.offset, extensions.next)
  };
}

function validateName(reader: PostgresDerReader,
  name: PostgresDerElement, allowEmpty: boolean): void {
  if (name.start === name.end) {
    if (allowEmpty) return;
    throw invalidCertificateIdentity();
  }
  let offset = name.start;
  while (offset < name.end) {
    const rdn = reader.expected(offset, name.end, 0x31);
    if (rdn.start === rdn.end) throw invalidCertificateIdentity();
    let attributeOffset = rdn.start;
    let previousOffset = -1;
    let previousEnd = -1;
    while (attributeOffset < rdn.end) {
      const attribute =
        reader.expected(attributeOffset, rdn.end, 0x30);
      const oid = reader.expected(attribute.start, attribute.end, 0x06);
      if (!reader.validOidValue(oid)) throw invalidCertificateIdentity();
      const value = reader.read(oid.next, attribute.end);
      if (value.next !== attribute.end) {
        throw invalidCertificateIdentity();
      }
      reader.validateValue(value, 0);
      validateCanonicalSets(reader, value, 0);
      if (previousOffset >= 0 && reader.compare(
        previousOffset, previousEnd,
        attributeOffset, attribute.next) > 0) {
        throw invalidCertificateIdentity();
      }
      previousOffset = attributeOffset;
      previousEnd = attribute.next;
      attributeOffset = attribute.next;
    }
    offset = rdn.next;
  }
}

function validateAlgorithmIdentifier(reader: PostgresDerReader,
  algorithm: PostgresDerElement): void {
  const oid = reader.expected(algorithm.start, algorithm.end, 0x06);
  if (!reader.validOidValue(oid)) throw invalidCertificateIdentity();
  if (oid.next === algorithm.end) return;
  const parameters = reader.read(oid.next, algorithm.end);
  if (parameters.next !== algorithm.end) {
    throw invalidCertificateIdentity();
  }
  reader.validateValue(parameters, 0);
}

function validateValidity(reader: PostgresDerReader,
  validity: PostgresDerElement): void {
  const notBefore = reader.read(validity.start, validity.end);
  const notAfter = reader.read(notBefore.next, validity.end);
  if (notAfter.next !== validity.end ||
    !reader.validCertificateTime(notBefore) ||
    !reader.validCertificateTime(notAfter)) {
    throw invalidCertificateIdentity();
  }
}

function validateSubjectPublicKeyInfo(reader: PostgresDerReader,
  subjectPublicKeyInfo: PostgresDerElement): void {
  const algorithm = reader.expected(
    subjectPublicKeyInfo.start, subjectPublicKeyInfo.end, 0x30);
  validateAlgorithmIdentifier(reader, algorithm);
  const subjectPublicKey = reader.expected(
    algorithm.next, subjectPublicKeyInfo.end, 0x03);
  if (subjectPublicKey.next !== subjectPublicKeyInfo.end ||
    subjectPublicKey.end - subjectPublicKey.start < 2 ||
    !reader.validBitString(subjectPublicKey)) {
    throw invalidCertificateIdentity();
  }
}

function invalidCertificateIdentity(): ArkDbError {
  return ArkDbError.tls(
    'Invalid PostgreSQL TLS certificate identity',
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}
