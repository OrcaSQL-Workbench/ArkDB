import { socket } from '@kit.NetworkKit';
import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  buildPostgresTlsConnectOptions, createDefaultPostgresTlsIdentityVerifier,
  PostgresTlsFilePort, postgresCertificateHasSubjectAlternativeName
} from '../../../main/ets/pgsql/transport/PostgresTcpTransport';
import {
  PostgresCertificateStructure, PostgresCertificateSubjectAlternativeName,
  PostgresSubjectAlternativeNames,
  postgresParseCertificateStructure,
  postgresParseCertificateSubjectAlternativeName,
  postgresParseSubjectAlternativeNamesEntry
} from '../../../main/ets/pgsql/transport/PostgresCertificateDer';
import { PostgresSslConfig, PostgresSslMode } from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
const SUBJECT_ALTERNATIVE_NAME_OID: number[] = [0x55, 0x1d, 0x11];
const BASIC_CONSTRAINTS_OID: number[] = [0x55, 0x1d, 0x13];
export default function postgresTlsTest(): void {
  describe('PostgresTls', () => {
    it('buildsModeSpecificTlsOptionsAndLoadsBoundedCredentials', 0, () => {
      const files = new MockTlsFiles();
      const required = new PostgresSslConfig();
      required.mode = PostgresSslMode.REQUIRED;
      required.caCertPath = 'ca.pem';
      let options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        required, 0xFFFFFFFF, files);
      expect(options.address.address).assertEqual('db.example.com');
      expect(options.address.port).assertEqual(5432);
      expect(options.timeout).assertEqual(0xFFFFFFFF);
      expect(options.skipRemoteValidation).assertTrue();
      expect(options.secureOptions.ca === undefined).assertTrue();
      expect(files.readPaths.length).assertEqual(0);
      const verified = new PostgresSslConfig();
      verified.mode = PostgresSslMode.VERIFY_CA;
      verified.caCertPath = ' ca.pem ';
      verified.clientCertPath = ' client.pem ';
      verified.clientKeyPath = ' key.pem ';
      verified.tlsVersions = ['TLSv1.2', 'TLSv1.3'];
      verified.cipherSuites = ' TLS_AES_128_GCM_SHA256 ';
      options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        verified, 3000, files);
      expect(options.skipRemoteValidation).assertFalse();
      expect(options.secureOptions.ca).assertEqual('CA');
      expect(options.secureOptions.cert).assertEqual('CERT');
      expect(options.secureOptions.key).assertEqual('KEY');
      expect(options.secureOptions.isBidirectionalAuthentication).assertTrue();
      expect(options.secureOptions.cipherSuite)
        .assertEqual('TLS_AES_128_GCM_SHA256');
      const protocols = options.secureOptions.protocols!;
      expect(protocols.length).assertEqual(2);
      expect(protocols[0]).assertEqual(socket.Protocol.TLSv12);
      expect(protocols[1]).assertEqual(socket.Protocol.TLSv13);
      expect(files.readPaths.join(','))
        .assertEqual('ca.pem,client.pem,key.pem');
      expect(files.maximumBytes).assertEqual(1024 * 1024);
      const verifyFull = new PostgresSslConfig();
      verifyFull.mode = PostgresSslMode.VERIFY_FULL;
      options = buildPostgresTlsConnectOptions('db.example.com', 5432,
        verifyFull, 1, files);
      expect(options.skipRemoteValidation).assertFalse();
    });
    it('rejectsDisabledTlsInvalidCredentialsVersionsAndFiles', 0, () => {
      const files = new MockTlsFiles();
      const config = new PostgresSslConfig();
      config.mode = PostgresSslMode.DISABLED;
      expectOptionsFailure(config, files, 1000, 'PostgreSQL TLS is disabled');
      config.mode = 'invalid' as PostgresSslMode;
      expectOptionsFailure(config, files, 1000,
        'Unsupported PostgreSQL TLS mode: invalid');
      config.mode = PostgresSslMode.REQUIRED;
      for (const timeout of [
        0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, 0x100000000
      ]) {
        expectOptionsFailure(config, files, timeout,
          'PostgreSQL TLS timeout must be between 1 and 4294967295 milliseconds');
      }
      config.clientCertPath = 'client.pem';
      expectOptionsFailure(config, files, 1000,
        'Client certificate and private key must be configured together');
      config.clientCertPath = undefined;
      config.clientKeyPath = 'key.pem';
      expectOptionsFailure(config, files, 1000,
        'Client certificate and private key must be configured together');
      config.clientCertPath = 'client.pem';
      config.tlsVersions = ['TLSv1.1'];
      expectOptionsFailure(config, files, 1000,
        'Unsupported TLS version: TLSv1.1');
      config.tlsVersions = ['TLSv1.2', ''];
      expectOptionsFailure(config, files, 1000, 'Unsupported TLS version: ');
      config.tlsVersions = ['TLSv1.2'];
      files.failedPath = 'client.pem';
      files.failedMessage = 'client certificate file must be between 1 byte and 1 MiB';
      expectOptionsFailure(config, files, 1000,
        'Could not read client certificate file: ' + files.failedMessage);
    });
    it('parsesBoundedCertificateStructureAndOptionalFields', 0, () => {
      expect(postgresParseCertificateStructure(
        certificate(tbsFields(null))).extensions === null).assertTrue();
      const v2Fields = tbsFields(1);
      v2Fields.push(element(0x81, bytes([0])));
      v2Fields.push(element(0x82, bytes([0])));
      expect(postgresParseCertificateStructure(
        certificate(v2Fields)).extensions === null).assertTrue();
      const rawExtensions = element(0x30, certificateExtension());
      const v3Fields = tbsFields();
      v3Fields.push(element(0xa3, rawExtensions));
      const encoded = certificate(v3Fields);
      const parsed: PostgresCertificateStructure =
        postgresParseCertificateStructure(encoded);
      assertBytes(parsed.extensions!, rawExtensions);
      parsed.extensions![2] = 0xff;
      const reparsed = postgresParseCertificateStructure(encoded);
      assertBytes(reparsed.extensions!, rawExtensions);
      expect(parsed.extensions === reparsed.extensions).assertFalse();
      postgresParseCertificateStructure(replaceTbsField(
        5, element(0x30, new Uint8Array(0))));
      postgresParseCertificateStructure(replaceTbsField(
        3, multiValuedName('a', 'b')));
      postgresParseCertificateStructure(certificateWithValidity(
        '240229000000Z', '250228000000Z'));
      const deepAlgorithm = algorithmIdentifier(nestedValue(32));
      const deepFields = tbsFields();
      deepFields[2] = deepAlgorithm;
      postgresParseCertificateStructure(certificate(
        deepFields, deepAlgorithm));
    });
    it('distinguishesExtensionlessNonSanAndSanCertificates', 0, () => {
      const absent: PostgresCertificateSubjectAlternativeName =
        postgresParseCertificateSubjectAlternativeName(
          certificate(tbsFields()));
      expect(absent.present).assertFalse();
      expect(absent.entryValue === null).assertTrue();
      const nonSanFields = tbsFields();
      nonSanFields.push(extensions(certificateExtension()));
      const nonSan = postgresParseCertificateSubjectAlternativeName(
        certificate(nonSanFields));
      expect(nonSan.present).assertFalse();
      expect(nonSan.entryValue === null).assertTrue();
      expect(postgresCertificateHasSubjectAlternativeName(
        certificate(nonSanFields))).assertFalse();
      const sanValue = element(0x04, bytes([0x30, 0x02, 0x82, 0]));
      const sanExtension = certificateExtension(
        SUBJECT_ALTERNATIVE_NAME_OID, sanValue);
      const sanFields = tbsFields();
      sanFields.push(extensions(sanExtension));
      const sanCertificate = certificate(sanFields);
      const parsed = postgresParseCertificateSubjectAlternativeName(
        sanCertificate);
      expect(parsed.present).assertTrue();
      expect(parsed.entryValue === null).assertFalse();
      assertBytes(parsed.entryValue!, sanValue);
      expect(postgresCertificateHasSubjectAlternativeName(
        sanCertificate)).assertTrue();
      parsed.entryValue![5] = 1;
      const reparsed = postgresParseCertificateSubjectAlternativeName(
        sanCertificate);
      assertBytes(reparsed.entryValue!, sanValue);
      expect(parsed.entryValue === reparsed.entryValue).assertFalse();
      const criticalSanFields = tbsFields();
      criticalSanFields.push(extensions(certificateExtension(
        SUBJECT_ALTERNATIVE_NAME_OID, sanValue, 0xff)));
      expect(postgresCertificateHasSubjectAlternativeName(
        certificate(criticalSanFields))).assertTrue();
      expect(postgresCertificateHasSubjectAlternativeName(certificate(
        withTail([
          element(0x81, bytes([0])),
          element(0x82, bytes([0])),
          extensions(sanExtension)
        ])))).assertTrue();
    });
    it('parsesNestedOctetStringGeneralNamesAndTypedCandidates', 0, () => {
      const dns = ascii('db.example.com');
      const ipv4 = bytes([127, 0, 0, 1]);
      const ipv6 = bytes([
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1
      ]);
      const entry = sanEntry([
        generalName(0x86, ascii('postgres://db.example.com')),
        generalName(0x87, ipv4),
        generalName(0x82, dns),
        generalName(0x82, dns),
        generalName(0x87, ipv6),
        generalName(0x81, ascii('postgres@example.com')),
        generalName(0xa0, concatenate([
          element(0x06, bytes([0x2a, 0x03])),
          element(0xa0, element(0x0c, ascii('value')))
        ])),
        generalName(0xa4, name('directory')),
        generalName(0xa5, concatenate([
          element(0xa0, element(0x13, ascii('assigner'))),
          element(0xa1, element(0x0c, ascii('party')))
        ])),
        generalName(0x88, bytes([0x2a, 0x03]))
      ]);
      const parsed: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(entry);
      expect(parsed.dnsNames.length).assertEqual(2);
      assertBytes(parsed.dnsNames[0], dns);
      assertBytes(parsed.dnsNames[1], dns);
      expect(parsed.ipAddresses.length).assertEqual(2);
      assertBytes(parsed.ipAddresses[0], ipv4);
      assertBytes(parsed.ipAddresses[1], ipv6);
      assertNumbers(parsed.otherGeneralNameTags,
        [0x86, 0x81, 0xa0, 0xa4, 0xa5, 0x88]);
    });
    it('rejectsMalformedGeneralNamesTagsFormsAsciiAndLengths', 0, () => {
      const valid = generalName(0x82, ascii('db.example.com'));
      for (const malformed of [
        bytes([0x30, 0]),
        bytes([0x04, 0x80, 0, 0]),
        bytes([0x04, 0x81, 0x02, 0x30, 0]),
        bytes([0x04, 0x82, 0, 0x80]),
        bytes([0x04, 0x85, 0, 0, 0, 0, 0]),
        bytes([0x04, 0x03, 0x30, 0]),
        concatenate([sanEntry([valid]), bytes([0])]),
        element(0x04, concatenate([
          element(0x30, valid), bytes([0])
        ])),
        element(0x04, element(0x31, valid)),
        sanEntry([]),
        sanEntry([generalName(0x80, bytes([1]))]),
        sanEntry([generalName(0xa1, element(0x16, ascii('mail')))]),
        sanEntry([generalName(0xa2, element(0x16, ascii('dns')))]),
        sanEntry([generalName(0x83, bytes([1]))]),
        sanEntry([generalName(0x84, bytes([1]))]),
        sanEntry([generalName(0x85, bytes([1]))]),
        sanEntry([generalName(0xa6, element(0x16, ascii('uri')))]),
        sanEntry([generalName(0xa7,
          element(0x04, bytes([127, 0, 0, 1])))]),
        sanEntry([generalName(0xa8,
          element(0x06, bytes([0x2a, 0x03])))]),
        sanEntry([generalName(0x89, bytes([1]))]),
        sanEntry([generalName(0x82, new Uint8Array(0))]),
        sanEntry([generalName(0x82, bytes([0x80]))]),
        sanEntry([generalName(0x82, repeatedAscii(0x61, 254))]),
        sanEntry([generalName(0x81, new Uint8Array(0))]),
        sanEntry([generalName(0x81, bytes([0x80]))]),
        sanEntry([generalName(0x86, new Uint8Array(0))]),
        sanEntry([generalName(0x86, bytes([0x80]))]),
        sanEntry([generalName(0x87, bytes([127, 0, 0]))]),
        sanEntry([generalName(0x87, new Uint8Array(5))]),
        sanEntry([generalName(0x87, new Uint8Array(15))]),
        sanEntry([generalName(0x87, new Uint8Array(17))]),
        sanEntry([generalName(0x88, new Uint8Array(0))]),
        sanEntry([generalName(0x88, bytes([0x80]))]),
        sanEntry([generalName(0x88, bytes([0x2a, 0x80, 0]))]),
        sanEntry([generalName(0xa3,
          element(0x30, element(0x80, ascii('123'))))])
      ]) {
        expectSubjectAlternativeNamesEntryFailure(malformed);
      }
    });
    it('validatesConstructedAndNonDnsGeneralNames', 0, () => {
      const oid = element(0x06, bytes([0x2a, 0x03]));
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x31, concatenate([
            element(0x01, bytes([0xff])),
            element(0x02, bytes([1]))
          ])))
        ])),
        generalName(0xa4, nameValue(element(0x30, element(0x31,
          concatenate([
            element(0x01, bytes([0xff])),
            element(0x02, bytes([1]))
          ]))))),
        generalName(0xa5, concatenate([
          element(0xa0, element(0x13, ascii('assigner'))),
          element(0xa1, element(0x1c, bytes([0, 0, 0, 0x41])))
        ])),
        generalName(0xa5,
          element(0xa1, element(0x1e, bytes([0, 0x41]))))
      ]));
      for (const malformed of [
        sanEntry([generalName(0xa0, new Uint8Array(0))]),
        sanEntry([generalName(0xa0, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, new Uint8Array(0))
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, concatenate([
            element(0x05, new Uint8Array(0)),
            element(0x05, new Uint8Array(0))
          ]))
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x30, bytes([0, 0])))
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x30, bytes([0x1f, 1, 0])))
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x31, concatenate([
            element(0x02, bytes([1])),
            element(0x01, bytes([0xff]))
          ])))
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x05, new Uint8Array(0))),
          element(0x05, new Uint8Array(0))
        ]))]),
        sanEntry([generalName(0xa4, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa4,
          element(0x30, new Uint8Array(0)))]),
        sanEntry([generalName(0xa4,
          element(0x30, element(0x31, new Uint8Array(0))))]),
        sanEntry([generalName(0xa4, nameValue(element(0x31, concatenate([
          element(0x02, bytes([1])),
          element(0x01, bytes([0xff]))
        ]))))]),
        sanEntry([generalName(0xa5, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa5,
          element(0xa0, element(0x0c, ascii('assigner'))))]),
        sanEntry([generalName(0xa5,
          element(0xa1, element(0x0c, new Uint8Array(0))))]),
        sanEntry([generalName(0xa5,
          element(0xa1, element(0x14, ascii('party'))))]),
        sanEntry([generalName(0xa5,
          element(0xa1, element(0x16, ascii('party'))))]),
        sanEntry([generalName(0xa5, concatenate([
          element(0xa1, element(0x0c, ascii('party'))),
          element(0xa0, element(0x0c, ascii('assigner')))
        ]))]),
        sanEntry([generalName(0xa5, concatenate([
          element(0xa1, element(0x0c, ascii('party'))),
          element(0xa1, element(0x0c, ascii('again')))
        ]))]),
        sanEntry([generalName(0xa5,
          element(0xa1, concatenate([
            element(0x0c, ascii('party')),
            element(0x0c, ascii('again'))
          ])))])
      ]) {
        expectSubjectAlternativeNamesEntryFailure(malformed);
      }
    });
    it('enforcesGeneralNamesCapsBoundariesAndDefensiveCopies', 0, () => {
      const boundaries: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(sanEntry([
          generalName(0x82, repeatedAscii(0x61, 127)),
          generalName(0x82, repeatedAscii(0x62, 128)),
          generalName(0x82, repeatedAscii(0x63, 253))
        ]));
      expect(boundaries.dnsNames[0].length).assertEqual(127);
      expect(boundaries.dnsNames[1].length).assertEqual(128);
      expect(boundaries.dnsNames[2].length).assertEqual(253);
      const maximumNames: Uint8Array[] = [];
      for (let index: number = 0; index < 256; index += 1) {
        maximumNames.push(generalName(0x86, bytes([0x78])));
      }
      const maximum: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(sanEntry(maximumNames));
      expect(maximum.otherGeneralNameTags.length).assertEqual(256);
      maximumNames.push(generalName(0x86, bytes([0x78])));
      expectSubjectAlternativeNamesEntryFailure(sanEntry(maximumNames));
      expectSubjectAlternativeNamesEntryFailure(
        new Uint8Array(64 * 1024 + 1));
      const encoded = sanEntry([
        generalName(0x82, ascii('copy.example.com')),
        generalName(0x87, bytes([127, 0, 0, 1]))
      ]);
      const original = copyBytes(encoded);
      const parsed: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(encoded);
      encoded[encoded.length - 1] = 2;
      assertBytes(parsed.ipAddresses[0], bytes([127, 0, 0, 1]));
      parsed.dnsNames[0][0] = 0;
      parsed.ipAddresses[0][0] = 0;
      const reparsed: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(original);
      assertBytes(reparsed.dnsNames[0], ascii('copy.example.com'));
      assertBytes(reparsed.ipAddresses[0], bytes([127, 0, 0, 1]));
    });
    it('rejectsMalformedExtensionsAndStructuralDecoys', 0, () => {
      const sanValue = element(0x04, bytes([0x30, 0]));
      const san = certificateExtension(
        SUBJECT_ALTERNATIVE_NAME_OID, sanValue);
      const malformedNonSan = element(0x30, concatenate([
        element(0x06, new Uint8Array(BASIC_CONSTRAINTS_OID)),
        element(0x02, bytes([1]))
      ]));
      const malformed: Uint8Array[] = [
        certificate(withTail([extensions(concatenate([san, san]))])),
        certificate(withTail([extensions(new Uint8Array(0))])),
        certificate(withTail([extensions(element(0x30, concatenate([
          element(0x06, bytes([0x80])),
          element(0x04, new Uint8Array(0))
        ])))])),
        certificate(withTail([extensions(element(0x30, concatenate([
          element(0x06, bytes([0x2a, 0x80, 0])),
          element(0x04, new Uint8Array(0))
        ])))])),
        certificate(withTail([extensions(certificateExtension(
          SUBJECT_ALTERNATIVE_NAME_OID, sanValue, 0))])),
        certificate(withTail([extensions(certificateExtension(
          SUBJECT_ALTERNATIVE_NAME_OID, sanValue, 1))])),
        certificate(withTail([extensions(element(0x30, concatenate([
          element(0x06, new Uint8Array(SUBJECT_ALTERNATIVE_NAME_OID)),
          element(0x01, bytes([0xff, 0xff])), sanValue
        ])))])),
        certificate(withTail([extensions(element(0x30,
          element(0x06, new Uint8Array(SUBJECT_ALTERNATIVE_NAME_OID))))])),
        certificate(withTail([extensions(element(0x30, concatenate([
          element(0x06, new Uint8Array(SUBJECT_ALTERNATIVE_NAME_OID)),
          element(0x02, bytes([1]))
        ])))])),
        certificate(withTail([extensions(element(0x30, concatenate([
          element(0x06, new Uint8Array(SUBJECT_ALTERNATIVE_NAME_OID)),
          sanValue, element(0x05, new Uint8Array(0))
        ])))])),
        certificate(withTail([extensions(concatenate([
          malformedNonSan, san
        ]))])),
        certificate(withTail([extensions(concatenate([
          san, malformedNonSan
        ]))]))
      ];
      for (const encoded of malformed) {
        expectSubjectAlternativeNameFailure(encoded);
      }
      const decoyFields = tbsFields();
      decoyFields.push(extensions(certificateExtension(
        BASIC_CONSTRAINTS_OID,
        element(0x04, bytes([0x06, 0x03, 0x55, 0x1d, 0x11])))));
      const signatureDecoy = certificate(
        decoyFields, algorithmIdentifier(),
        bytes([0, 0x06, 0x03, 0x55, 0x1d, 0x11]));
      expect(postgresCertificateHasSubjectAlternativeName(
        signatureDecoy)).assertFalse();
      const oidDecoyFields = tbsFields();
      oidDecoyFields.push(extensions(certificateExtension(
        [0x2a, 0x55, 0x1d, 0x11], sanValue)));
      expect(postgresCertificateHasSubjectAlternativeName(
        certificate(oidDecoyFields))).assertFalse();
    });
    it('enforcesExtensionAllocationCapsAndDefensiveCopies', 0, () => {
      const maximumValue = element(
        0x04, new Uint8Array(64 * 1024 - 13));
      const maximumFields = tbsFields();
      maximumFields.push(extensions(certificateExtension(
        BASIC_CONSTRAINTS_OID, maximumValue)));
      expect(postgresCertificateHasSubjectAlternativeName(
        certificate(maximumFields))).assertFalse();
      const oversizedFields = tbsFields();
      oversizedFields.push(extensions(certificateExtension(
        BASIC_CONSTRAINTS_OID,
        element(0x04, new Uint8Array(64 * 1024 - 12)))));
      expectSubjectAlternativeNameFailure(certificate(oversizedFields));
      const records: Uint8Array[] = [];
      for (let index: number = 0; index < 256; index += 1) {
        records.push(certificateExtension(
          extensionOid(index), element(0x04, new Uint8Array(0))));
      }
      const acceptedFields = tbsFields();
      acceptedFields.push(extensions(concatenate(records)));
      expect(postgresCertificateHasSubjectAlternativeName(
        certificate(acceptedFields))).assertFalse();
      records.push(certificateExtension(
        extensionOid(256), element(0x04, new Uint8Array(0))));
      const rejectedFields = tbsFields();
      rejectedFields.push(extensions(concatenate(records)));
      expectSubjectAlternativeNameFailure(certificate(rejectedFields));
    });
    it('supportsBoundedCertificateDerLengths', 0, () => {
      const shortCertificate = certificate(tbsFields());
      expect((shortCertificate[1] & 0x80) === 0).assertTrue();
      postgresParseCertificateStructure(shortCertificate);
      for (const length of [128, 256, 64 * 1024]) {
        const encoded = certificate(tbsFields(), algorithmIdentifier(),
          concatenate([bytes([0, 1]), new Uint8Array(length)]));
        expect((encoded[1] & 0x80) !== 0).assertTrue();
        postgresParseCertificateStructure(encoded);
      }
      for (const encoded of [
        bytes([0x30, 0x80, 0, 0]),
        concatenate([bytes([0x30, 0x81, 0x7f]), new Uint8Array(0x7f)]),
        concatenate([bytes([0x30, 0x82, 0, 0x80]), new Uint8Array(0x80)]),
        bytes([0x30, 0x85, 0, 0, 0, 0, 0]),
        bytes([0x30, 0x84, 0xff, 0xff, 0xff, 0xff]),
        bytes([0x30, 0x82, 1]), bytes([0, 0]), bytes([0x3f, 1, 0]),
        bytes([0x31, 0]),
        concatenate([shortCertificate, bytes([0])])
      ]) {
        expectCertificateFailure(encoded);
      }
    });
    it('rejectsMalformedCertificateStructureAndEncodings', 0, () => {
      const fields = tbsFields();
      const duplicateIssuerId = tbsFields(1);
      duplicateIssuerId.push(element(0x81, bytes([0])));
      duplicateIssuerId.push(element(0x81, bytes([0])));
      const reversedUniqueIds = tbsFields(1);
      reversedUniqueIds.push(element(0x82, bytes([0])));
      reversedUniqueIds.push(element(0x81, bytes([0])));
      const afterExtensions = tbsFields();
      afterExtensions.push(extensions(certificateExtension()));
      afterExtensions.push(element(0x82, bytes([0])));
      const overDepthAlgorithm = algorithmIdentifier(nestedValue(33));
      const overDepthFields = tbsFields();
      overDepthFields[2] = overDepthAlgorithm;
      for (const encoded of [
        bytes([0x30, 0]),
        certificate(fields.slice(0, 2)),
        replaceTbsField(1, element(0x02, new Uint8Array(0))),
        replaceTbsField(1, element(0x02, bytes([0, 1]))),
        replaceTbsField(2, element(0x30, new Uint8Array(0))),
        replaceTbsField(2, algorithmIdentifier(bytes([0, 0]))),
        replaceTbsField(3, element(0x30, new Uint8Array(0))),
        replaceTbsField(4, element(0x30, new Uint8Array(0))),
        certificateWithValidity('261300000000Z', '271110000000Z'),
        certificateWithValidity('260431000000Z', '271110000000Z'),
        certificateWithValidity('261110240000Z', '271110000000Z'),
        certificateWithValidity('261110006000Z', '271110000000Z'),
        certificateWithValidity('261110000060Z', '271110000000Z'),
        certificateWithValidity('230229000000Z', '271110000000Z'),
        replaceTbsField(6, element(0x30, new Uint8Array(0))),
        replaceTbsField(6, element(0x30, concatenate([
          algorithmIdentifier(), element(0x03, bytes([0]))
        ]))),
        certificate(fields, algorithmIdentifier(), new Uint8Array(0)),
        certificate(fields, algorithmIdentifier(), bytes([0])),
        certificate(fields, algorithmIdentifier(), bytes([8, 1])),
        replaceTbsField(0, element(0xa0, element(0x02, bytes([3])))),
        replaceTbsField(0, element(0xa0, new Uint8Array(0))),
        certificate(duplicateIssuerId), certificate(reversedUniqueIds),
        certificate(afterExtensions), certificate(withTail([
          element(0xa3, element(0x30, new Uint8Array(0)))
        ])), certificate(withTail([element(0xa3, concatenate([
          element(0x30, certificateExtension()), element(0x05, new Uint8Array(0))
        ]))])), certificate(overDepthFields, overDepthAlgorithm)
      ]) {
        expectCertificateFailure(encoded);
      }
      for (const value of [
        element(0x01, bytes([1])), element(0x02, new Uint8Array(0)),
        element(0x03, bytes([8])), element(0x05, bytes([0])),
        element(0x06, bytes([0x80])), element(0x0c, bytes([0xff])),
        element(0x14, bytes([0x0a])), element(0x16, bytes([0x80])),
        element(0x30, bytes([0, 0])), element(0x30, bytes([0x3f, 1, 0]))
      ]) {
        expectCertificateFailure(replaceTbsField(3, nameValue(value)));
      }
    });
    it('rejectsVersionSignatureAndRdnReviewRegressions', 0, () => {
      const reviewVectors: Uint8Array[] = [
        certificate(tbsFields(0)),
        certificate(withTail([element(0x81, bytes([0]))], null)),
        certificate(withTail([extensions(certificateExtension())], null)),
        certificate(withTail([extensions(certificateExtension())], 1)),
        certificate(tbsFields(), algorithmIdentifier(null, [0x2a, 0x04])),
        replaceTbsField(3, multiValuedName('b', 'a'))
      ];
      let accepted: number = 0;
      for (const encoded of reviewVectors) {
        try {
          postgresParseCertificateStructure(encoded);
          accepted += 1;
        } catch (error) {
        }
      }
      expect(accepted).assertEqual(0);
    });
    it('enforcesCertificateStructureAllocationCaps', 0, () => {
      expectCertificateFailure(new Uint8Array(1024 * 1024 + 1));
      const maximum = new Uint8Array(64 * 1024);
      const valid = withTail([element(0xa3, element(0x30, maximum))]);
      expect(postgresParseCertificateStructure(
        certificate(valid)).extensions!.length > maximum.length).assertTrue();
      expectCertificateFailure(certificate(withTail([
        element(0xa3, element(0x30, new Uint8Array(64 * 1024 + 1)))
      ])));
    });
    it('failsClosedWhenVerifyFullHasNoProductionIdentityVerifier', 0, async () => {
      const verifier = createDefaultPostgresTlsIdentityVerifier();
      const certificate = {} as socket.X509CertRawData;
      const terminal = await failure((): Promise<void> =>
        verifier.verify(certificate, 'db.example.com'));
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(terminal.nativeCode).assertEqual(
        'TLS_IDENTITY_VERIFIER_UNAVAILABLE');
      expect(terminal.message).assertEqual(
        'PostgreSQL VERIFY_FULL identity verification is not available in this build');
    });
  });
}
class MockTlsFiles implements PostgresTlsFilePort {
  maximumBytes: number = 0;
  readPaths: string[] = [];
  failedPath: string = '';
  failedMessage: string = '';
  read(path: string, maximumBytes: number, label: string): string {
    this.maximumBytes = maximumBytes;
    this.readPaths.push(path);
    if (path === this.failedPath) throw new Error(this.failedMessage);
    if (path === 'ca.pem') return 'CA';
    if (path === 'client.pem') return 'CERT';
    if (path === 'key.pem') return 'KEY';
    throw new Error('Unexpected TLS fixture path for ' + label);
  }
}
function certificate(fields: Uint8Array[],
  signatureAlgorithm: Uint8Array = algorithmIdentifier(),
  signature: Uint8Array = bytes([0, 1])): Uint8Array {
  return element(0x30, concatenate([
    element(0x30, concatenate(fields)), signatureAlgorithm,
    element(0x03, signature)
  ]));
}
function tbsFields(version: number | null = 2): Uint8Array[] {
  const fields: Uint8Array[] = [
    element(0x02, bytes([1])), algorithmIdentifier(), name('issuer'),
    element(0x30, concatenate([
      element(0x17, ascii('261110000000Z')),
      element(0x17, ascii('271110000000Z'))
    ])), name('subject'), element(0x30, concatenate([
      algorithmIdentifier(), element(0x03, bytes([0, 1]))
    ]))
  ];
  if (version !== null) {
    fields.unshift(element(0xa0, element(0x02, bytes([version]))));
  }
  return fields;
}
function replaceTbsField(index: number, value: Uint8Array): Uint8Array {
  const fields = tbsFields();
  fields[index] = value;
  return certificate(fields);
}
function certificateWithValidity(
  notBefore: string, notAfter: string): Uint8Array {
  return replaceTbsField(4, element(0x30, concatenate([
    element(0x17, ascii(notBefore)), element(0x17, ascii(notAfter))
  ])));
}
function withTail(tail: Uint8Array[], version: number | null = 2): Uint8Array[] {
  const fields = tbsFields(version);
  for (const value of tail) fields.push(value);
  return fields;
}
function algorithmIdentifier(
  parameters: Uint8Array | null = null,
  oid: number[] = [0x2a, 0x03]): Uint8Array {
  const fields: Uint8Array[] = [element(0x06, new Uint8Array(oid))];
  if (parameters !== null) fields.push(parameters);
  return element(0x30, concatenate(fields));
}
function name(value: string): Uint8Array {
  return nameValue(element(0x0c, ascii(value)));
}
function nameValue(value: Uint8Array): Uint8Array {
  return element(0x30, element(0x31, nameAttribute(value)));
}
function multiValuedName(first: string, second: string): Uint8Array {
  return element(0x30, element(0x31, concatenate([
    nameAttribute(element(0x0c, ascii(first))),
    nameAttribute(element(0x0c, ascii(second)))
  ])));
}
function nameAttribute(value: Uint8Array): Uint8Array {
  return element(0x30, concatenate([
    element(0x06, bytes([0x55, 0x04, 0x03])), value
  ]));
}
function extensions(content: Uint8Array): Uint8Array {
  return element(0xa3, element(0x30, content));
}
function certificateExtension(
  oid: number[] = BASIC_CONSTRAINTS_OID,
  value: Uint8Array =
    element(0x04, element(0x30, new Uint8Array(0))),
  critical: number | null = null): Uint8Array {
  const fields: Uint8Array[] = [element(0x06, new Uint8Array(oid))];
  if (critical !== null) {
    fields.push(element(0x01, bytes([critical])));
  }
  fields.push(value);
  return element(0x30, concatenate(fields));
}
function sanEntry(names: Uint8Array[]): Uint8Array {
  return element(0x04, element(0x30, concatenate(names)));
}
function generalName(tag: number, value: Uint8Array): Uint8Array {
  return element(tag, value);
}
function element(tag: number, value: Uint8Array): Uint8Array {
  let length: Uint8Array;
  if (value.length < 0x80) length = bytes([value.length]);
  else if (value.length <= 0xff) length = bytes([0x81, value.length]);
  else if (value.length <= 0xffff) {
    length = bytes([0x82, value.length >>> 8, value.length & 0xff]);
  } else {
    length = bytes([
      0x83, value.length >>> 16,
      (value.length >>> 8) & 0xff, value.length & 0xff
    ]);
  }
  return concatenate([bytes([tag]), length, value]);
}
function concatenate(parts: Uint8Array[]): Uint8Array {
  let length: number = 0;
  for (const part of parts) length += part.length;
  const result = new Uint8Array(length);
  let offset: number = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}
function ascii(value: string): Uint8Array {
  const result = new Uint8Array(value.length);
  for (let index: number = 0; index < value.length; index += 1) {
    result[index] = value.charCodeAt(index);
  }
  return result;
}
function repeatedAscii(value: number, length: number): Uint8Array {
  const result = new Uint8Array(length);
  for (let index: number = 0; index < length; index += 1) {
    result[index] = value;
  }
  return result;
}
function copyBytes(value: Uint8Array): Uint8Array {
  const result = new Uint8Array(value.length);
  result.set(value);
  return result;
}
function nestedValue(depth: number): Uint8Array {
  let value = element(0x05, new Uint8Array(0));
  for (let index: number = 0; index < depth; index += 1) {
    value = element(0x30, value);
  }
  return value;
}
function extensionOid(index: number): number[] {
  if (index < 0x80) return [0x2a, index];
  return [0x2a, 0x80 | (index >>> 7), index & 0x7f];
}
function bytes(values: number[]): Uint8Array {
  return new Uint8Array(values);
}
function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index: number = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
function assertNumbers(actual: number[], expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index: number = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
function expectCertificateFailure(encoded: Uint8Array): void {
  let terminal: ArkDbError | null = null;
  try {
    postgresParseCertificateStructure(encoded);
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.nativeCode).assertEqual(
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}
function expectSubjectAlternativeNameFailure(encoded: Uint8Array): void {
  let terminal: ArkDbError | null = null;
  try {
    postgresCertificateHasSubjectAlternativeName(encoded);
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.nativeCode).assertEqual(
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}
function expectSubjectAlternativeNamesEntryFailure(encoded: Uint8Array): void {
  let terminal: ArkDbError | null = null;
  try {
    postgresParseSubjectAlternativeNamesEntry(encoded);
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.nativeCode).assertEqual(
    'TLS_CERTIFICATE_IDENTITY_INVALID');
}
function expectOptionsFailure(config: PostgresSslConfig,
  files: PostgresTlsFilePort, timeoutMs: number, message: string): void {
  let terminal: ArkDbError | null = null;
  try {
    buildPostgresTlsConnectOptions(
      'db.example.com', 5432, config, timeoutMs, files);
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  expect(terminal!.kind).assertEqual(ArkDbErrorKind.Tls);
  expect(terminal!.message).assertEqual(message);
}
async function failure(operation: () => Promise<void>): Promise<ArkDbError> {
  let terminal: ArkDbError | null = null;
  try {
    await operation();
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  return terminal!;
}
