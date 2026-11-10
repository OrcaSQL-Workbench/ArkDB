import { ArkDbError } from '@arkdb/core';
import {
  PostgresDerElement, PostgresDerReader
} from './PostgresDer';

const MAX_POSTGRES_CERTIFICATE_DER_BYTES: number = 1024 * 1024;
const MAX_POSTGRES_CERTIFICATE_EXTENSION_BYTES: number = 64 * 1024;
const MAX_POSTGRES_DER_NESTING: number = 32;

export interface PostgresCertificateStructure {
  extensions: Uint8Array | null;
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
