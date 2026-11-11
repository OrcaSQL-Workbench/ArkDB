import { socket } from '@kit.NetworkKit';
import { cert as platformCert } from '@kit.DeviceCertificateKit';
import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  buildPostgresTlsConnectOptions, createDefaultPostgresTlsIdentityVerifier,
  NetworkKitPostgresPeerCertificate, PostgresDecodedCertificate,
  PostgresPeerCertificate, PostgresPeerCertificateFactory, PostgresTlsFilePort,
  postgresCertificateHasSubjectAlternativeName, postgresCertificateMatchesHost,
  postgresDnsNameMatchesHost, postgresIpAddressBytes
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
        generalName(0xa3, concatenate([
          element(0x30, concatenate([
            element(0x80, ascii('123')),
            element(0x83, ascii('Example'))
          ])),
          element(0x30, element(0x30, concatenate([
            element(0x13, ascii('type')),
            element(0x13, ascii('value'))
          ]))),
          element(0x31, element(0x30, concatenate([
            element(0x80, bytes([1])),
            element(0xa1, element(0x13, ascii('common')))
          ])))
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
        [0x86, 0x81, 0xa0, 0xa3, 0xa4, 0xa5, 0x88]);
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
        sanEntry([generalName(0x88, bytes([0x2a, 0x80, 0]))])
      ]) {
        expectSubjectAlternativeNamesEntryFailure(malformed);
      }
    });
    it('acceptsEmptyOptionalPdsParameterSets', 0, () => {
      for (const type of [
        10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21
      ]) {
        postgresParseSubjectAlternativeNamesEntry(sanEntry([
          x400Extension(type, element(0x31, new Uint8Array(0)))
        ]));
      }
    });
    it('acceptsEmptyOptionalUnformattedPostalAddressSet', 0, () => {
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        x400Extension(16, element(0x31, new Uint8Array(0)))
      ]));
    });
    it('validatesConstructedAndNonDnsGeneralNames', 0, () => {
      const oid = element(0x06, bytes([0x2a, 0x03]));
      const tagOrderedAmbiguousSet = element(0x31, concatenate([
        element(0xa0, element(0x02, bytes([1]))),
        element(0x81, bytes([1]))
      ]));
      const encodingOrderedAmbiguousSet = element(0x31, concatenate([
        element(0x81, bytes([1])),
        element(0xa0, element(0x02, bytes([1])))
      ]));
      const orderedSetOf = element(0x31, concatenate([
        element(0x02, bytes([1])),
        element(0x02, bytes([2]))
      ]));
      const reversedSetOf = element(0x31, concatenate([
        element(0x02, bytes([2])),
        element(0x02, bytes([1]))
      ]));
      const domainAttribute = element(0x30, concatenate([
        element(0x13, ascii('type')), element(0x13, ascii('value'))
      ]));
      const tooManyUnits: Uint8Array[] = [];
      const tooManyDomainAttributes: Uint8Array[] = [];
      for (let index: number = 0; index < 5; index += 1) {
        tooManyUnits.push(element(0x13, ascii('unit')));
        tooManyDomainAttributes.push(domainAttribute);
      }
      const extensionValues = x400ExtensionValues();
      expect(extensionValues.length).assertEqual(23);
      for (let index: number = 0; index < extensionValues.length; index += 1) {
        postgresParseSubjectAlternativeNamesEntry(sanEntry([
          x400Extension(index + 1, extensionValues[index])
        ]));
      }
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        x400Extension(2, element(0x14, concatenate([
          bytes([0x1b, 0x28, 0x75]), repeatedAscii(0x41, 64)
        ]))),
        x400Extension(3, element(0x14, concatenate([
          bytes([0xc1, 0x41]), repeatedAscii(0x42, 63)
        ]))),
        x400Extension(10, element(0x31, concatenate([
          element(0x13, ascii('printable')),
          element(0x14, ascii('teletex'))
        ]))),
        x400Extension(16, element(0x31, concatenate([
          element(0x30, element(0x13, ascii('line'))),
          element(0x14, ascii('teletex'))
        ])))
      ]));
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        generalName(0xa3, element(0x30, concatenate([
          element(0x61, element(0x13, ascii('US'))),
          element(0x62, element(0x12, ascii('123'))),
          element(0x80, ascii('123')),
          element(0x81, ascii('terminal')),
          element(0xa2, element(0x13, ascii('private'))),
          element(0x83, ascii('organization')),
          element(0x84, ascii('123')),
          element(0xa5, concatenate([
            element(0x80, ascii('surname')),
            element(0x81, ascii('given')),
            element(0x82, ascii('AB')),
            element(0x83, ascii('III'))
          ])),
          element(0xa6, concatenate([
            element(0x13, ascii('unit1')),
            element(0x13, ascii('unit2'))
          ]))
        ]))),
        x400Extension(22, element(0xa0, concatenate([
          element(0xa0, element(0x04, bytes([1]))),
          element(0xa1, element(0x04, bytes([2]))),
          element(0xa2, element(0x04, bytes([3]))),
          element(0xa3, element(0x31, concatenate([
            element(0x04, bytes([1])),
            element(0x04, bytes([2]))
          ])))
        ])))
      ]));
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x31, concatenate([
            element(0x01, bytes([0xff])),
            element(0x02, bytes([1]))
          ])))
        ])),
        generalName(0xa0, concatenate([
          oid, element(0xa0, orderedSetOf)
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
          element(0xa1, element(0x1e, bytes([0, 0x41])))),
        generalName(0xa5,
          element(0xa1, element(0x14, ascii('party'))))
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
          oid, element(0xa0, tagOrderedAmbiguousSet)
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, encodingOrderedAmbiguousSet)
        ]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, reversedSetOf)
        ]))]),
        sanEntry([kerberosOtherName(bytes([0x1b]))]),
        sanEntry([kerberosOtherName(bytes([0x1b, 0x28]))]),
        sanEntry([kerberosOtherName(bytes([0x1b, 0x28, 0x42]))]),
        sanEntry([kerberosOtherName(bytes([0x0e]))]),
        sanEntry([kerberosOtherName(bytes([0x0f]))]),
        sanEntry([generalName(0xa0, concatenate([
          oid, element(0xa0, element(0x05, new Uint8Array(0))),
          element(0x05, new Uint8Array(0))
        ]))]),
        sanEntry([generalName(0xa3,
          element(0x30, new Uint8Array(0)))]),
        sanEntry([generalName(0xa3, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x30, new Uint8Array(0))
        ]))]),
        sanEntry([generalName(0xa3,
          element(0x30, element(0x02, bytes([1]))))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x30, element(0x02, bytes([1])))
        ]))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x31, element(0x02, bytes([1])))
        ]))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x31, new Uint8Array(0))
        ]))]),
        sanEntry([generalName(0xa3, element(0x30, concatenate([
          element(0x83, ascii('organization')),
          element(0x80, ascii('123'))
        ])))]),
        sanEntry([generalName(0xa3, element(0x30, concatenate([
          element(0x80, ascii('123')), element(0x80, ascii('456'))
        ])))]),
        sanEntry([generalName(0xa3,
          element(0x30, element(0xa5,
            element(0x81, ascii('given')))))]),
        sanEntry([generalName(0xa3,
          element(0x30, element(0xa6, concatenate(tooManyUnits))))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x30, concatenate(tooManyDomainAttributes))
        ]))]),
        sanEntry([x400Extensions([
          x400ExtensionAttribute(2, element(0x14, ascii('two'))),
          x400ExtensionAttribute(1, element(0x13, ascii('one')))
        ])]),
        sanEntry([x400Extension(0, element(0x13, ascii('zero')))]),
        sanEntry([x400Extension(24, element(0x13, ascii('unsupported')))]),
        sanEntry([x400Extension(1, element(0x02, bytes([1])))]),
        sanEntry([x400Extension(1,
          element(0x13, repeatedAscii(0x61, 65)))]),
        sanEntry([x400Extension(2,
          element(0x14, bytes([0x1b, 0x28, 0x75])))]),
        sanEntry([x400Extension(10, element(0x31,
          element(0x13, new Uint8Array(0))))]),
        sanEntry([x400Extension(10, element(0x31, concatenate([
          element(0x13, ascii('one')), element(0x13, ascii('two'))
        ])))]),
        sanEntry([x400Extension(10, element(0x31, concatenate([
          element(0x14, ascii('teletex')),
          element(0x13, ascii('printable'))
        ])))]),
        sanEntry([x400Extension(16, element(0x31,
          element(0x30, new Uint8Array(0))))]),
        sanEntry([x400Extension(16, element(0x31, concatenate([
          element(0x14, ascii('teletex')),
          element(0x30, element(0x13, ascii('line')))
        ])))]),
        sanEntry([generalName(0xa3, concatenate([
          element(0x30, new Uint8Array(0)),
          element(0x31, element(0x30, concatenate([
            element(0x80, bytes([1])),
            element(0xa1, concatenate([
              element(0x13, ascii('one')),
              element(0x13, ascii('two'))
            ]))
          ])))
        ]))]),
        sanEntry([x400Extension(22,
          element(0x30, element(0x81, ascii('123'))))]),
        sanEntry([x400Extension(22, element(0xa0,
          element(0xa0, element(0x04, bytes([1])))))]),
        sanEntry([x400Extension(22, element(0xa0,
          element(0xa3, element(0x31, new Uint8Array(0)))))]),
        sanEntry([x400Extension(22, element(0xa0,
          element(0xa3, element(0x31, concatenate([
            element(0x04, bytes([2])), element(0x04, bytes([1]))
          ])))))]),
        sanEntry([x400Extension(23, element(0x02, bytes([1, 1])))]),
        sanEntry([generalName(0xa4, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa4,
          element(0x30, new Uint8Array(0)))]),
        sanEntry([generalName(0xa4,
          element(0x30, element(0x31, new Uint8Array(0))))]),
        sanEntry([generalName(0xa4, nameValue(element(0x31, concatenate([
          element(0x02, bytes([1])),
          element(0x01, bytes([0xff]))
        ]))))]),
        sanEntry([generalName(0xa4,
          nameValue(tagOrderedAmbiguousSet))]),
        sanEntry([generalName(0xa4,
          nameValue(encodingOrderedAmbiguousSet))]),
        sanEntry([generalName(0xa5, element(0x02, bytes([1])))]),
        sanEntry([generalName(0xa5,
          element(0xa0, element(0x0c, ascii('assigner'))))]),
        sanEntry([generalName(0xa5,
          element(0xa1, element(0x0c, new Uint8Array(0))))]),
        sanEntry([generalName(0xa5,
          element(0xa1, element(0x14,
            bytes([0x1b, 0x28, 0x75]))))]),
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
      const kerberos: PostgresSubjectAlternativeNames =
        postgresParseSubjectAlternativeNamesEntry(sanEntry([
          generalName(0x82, ascii('db.example.com')),
          kerberosOtherName(ascii('EXAMPLE.COM'))
        ]));
      assertBytes(kerberos.dnsNames[0], ascii('db.example.com'));
      assertNumbers(kerberos.otherGeneralNameTags, [0xa0]);
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
      const maximumExtensions: Uint8Array[] = [];
      for (let index: number = 0; index < 256; index += 1) {
        maximumExtensions.push(
          x400ExtensionAttribute(23, element(0x02, bytes([0]))));
      }
      postgresParseSubjectAlternativeNamesEntry(sanEntry([
        x400Extensions(maximumExtensions)
      ]));
      maximumExtensions.push(
        x400ExtensionAttribute(23, element(0x02, bytes([0]))));
      expectSubjectAlternativeNamesEntryFailure(sanEntry([
        x400Extensions(maximumExtensions)
      ]));
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
    it('matchesStrictDnsNamesAndWildcardDepth', 0, () => {
      expect(postgresDnsNameMatchesHost(
        'db.example.com', 'DB.EXAMPLE.COM.')).assertTrue();
      expect(postgresDnsNameMatchesHost(
        '*.example.com', 'db.example.com')).assertTrue();
      expect(postgresDnsNameMatchesHost(
        '*.example.com', 'nested.db.example.com')).assertFalse();
      for (const invalid of [
        '*.com', '*db.example.com', 'db.*.com', '*.*.com',
        ' db.example.com', 'db.example.com ', 'db.example.com.',
        '.db.example.com', 'db..example.com', '-db.example.com',
        'db-.example.com', 'a'.repeat(64) + '.example.com'
      ]) {
        expect(postgresDnsNameMatchesHost(
          invalid, 'db.example.com')).assertFalse();
      }
      for (const invalid of [
        ' db.example.com', 'db.example.com ', 'db.example.com..',
        '.db.example.com', 'db..example.com', '\u212A.example.com'
      ]) {
        expect(postgresDnsNameMatchesHost(
          'db.example.com', invalid)).assertFalse();
      }
      expect(postgresDnsNameMatchesHost(
        '\u212A.example.com', 'k.example.com')).assertFalse();
    });
    it('parsesCanonicalIpLiteralsWithoutDnsFallback', 0, () => {
      assertIp('127.0.0.1', [127, 0, 0, 1]);
      assertIp('2001:db8::1', [
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1
      ]);
      assertIp('::ffff:192.0.2.1', [
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0xff, 192, 0, 2, 1
      ]);
      for (const invalid of [
        '[2001:db8::1]', '127.00.0.1', '256.0.0.1',
        '2001:db8::1::2', '2001:db8::1%25eth0', '2001:db8:',
        '192.0.2.1::', '192.0.2.1::1', '192.0.2.1::192.0.2.2'
      ]) {
        expect(postgresIpAddressBytes(invalid) === null).assertTrue();
      }
      for (const legacy of [
        '0x7f000001', '017700000001', '2130706433', '0x7f.0.0.1'
      ]) {
        expect(postgresCertificateMatchesHost(
          peerWithSan(null, [legacy]), legacy)).assertFalse();
      }
      expect(postgresCertificateMatchesHost(
        peerWithNames([generalName(0x82, ascii('127.00.0.1'))],
          ['127.00.0.1']), '127.00.0.1')).assertFalse();
      const numericDns = '0x1.0x2.0x3.0x4.0x5';
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, [numericDns]), numericDns)).assertTrue();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, [numericDns]), numericDns + '.')).assertTrue();
    });
    it('usesSanBeforePermittedCnFallbackAndSeparatesDnsFromIp', 0, () => {
      let peer = peerWithNames([
        generalName(0x86, ascii('postgres://db.example.com')),
        generalName(0x87, bytes([127, 0, 0, 1])),
        generalName(0x82, ascii('db.example.com')),
        generalName(0x82, ascii('db.example.com'))
      ], ['wrong.example.com']);
      expect(postgresCertificateMatchesHost(
        peer, 'db.example.com')).assertTrue();
      expect(postgresCertificateMatchesHost(peer, '127.0.0.1')).assertTrue();
      expect(postgresCertificateMatchesHost(peer, '127.0.0.2')).assertFalse();

      peer = peerWithNames([
        generalName(0x82, ascii('wrong.example.com'))
      ], ['db.example.com']);
      expect(postgresCertificateMatchesHost(
        peer, 'db.example.com')).assertFalse();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, ['db.example.com']), 'db.example.com')).assertTrue();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, ['db.example.com'],
          [certificateExtension()]), 'db.example.com')).assertTrue();
      expect(postgresCertificateMatchesHost(peerWithNames([
        generalName(0x86, ascii('postgres://db.example.com')),
        generalName(0x87, bytes([127, 0, 0, 1])),
        generalName(0x88, bytes([0x2a, 0x03]))
      ], ['db.example.com']), 'db.example.com')).assertTrue();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, ['wrong.example.com', 'db.example.com']),
        'db.example.com')).assertFalse();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, ['db.example.com', 'wrong.example.com']),
        'db.example.com')).assertTrue();
      expect(postgresCertificateMatchesHost(
        peerWithSan(null, ['127.0.0.1']), '127.0.0.1')).assertFalse();
      expect(postgresCertificateMatchesHost(peerWithNames([
        generalName(0x82, ascii('127.0.0.1'))
      ], []), '127.0.0.1')).assertFalse();
    });
    it('rejectsInvalidPresentedNamesAndMalformedIdentityData', 0, () => {
      for (const invalid of [
        bytes([
          0x64, 0x62, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70,
          0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d, 0, 0x2e,
          0x61, 0x74, 0x74, 0x61, 0x63, 0x6b, 0x65, 0x72
        ]),
        ascii('db.example.com '), ascii('db..example.com'),
        ascii('db.example.com.')
      ]) {
        expect(postgresCertificateMatchesHost(peerWithNames([
          generalName(0x82, invalid)
        ], ['db.example.com']), 'db.example.com')).assertFalse();
      }
      let terminal = syncFailure((): void => {
        postgresCertificateMatchesHost(peerWithNames([
          generalName(0x82, bytes([0xff]))
        ], ['db.example.com']), 'db.example.com');
      });
      expect(terminal.nativeCode).assertEqual(
        'TLS_CERTIFICATE_IDENTITY_INVALID');
      terminal = syncFailure((): void => {
        postgresCertificateMatchesHost(
          peerWithSan(element(0x04, element(0x30, new Uint8Array(0))),
            ['db.example.com']), 'db.example.com');
      });
      expect(terminal.nativeCode).assertEqual(
        'TLS_CERTIFICATE_IDENTITY_INVALID');
      terminal = syncFailure((): void => {
        postgresCertificateMatchesHost(
          new MockPeerCertificate(
            bytes([0x30, 0]), new Uint8Array(0), ['db.example.com']),
          'db.example.com');
      });
      expect(terminal.nativeCode).assertEqual(
        'TLS_CERTIFICATE_IDENTITY_INVALID');
    });
    it('wiresProductionVerifierAndReturnsDefensiveIdentityCopies', 0, async () => {
      const encoded = certificate(tbsFields());
      const san = sanEntry([
        generalName(0x82, ascii('db.example.com'))
      ]);
      const commonNames = ['db.example.com'];
      const decoded = new MockDecodedCertificate(san, commonNames);
      const adapter = new NetworkKitPostgresPeerCertificate(
        decoded, encoded);
      const encodedCopy = adapter.certificateDer();
      const sanCopy = adapter.subjectAlternativeNameExtension();
      const commonNameCopy = adapter.subjectCommonNames();
      encodedCopy[0] = 0;
      sanCopy[0] = 0;
      commonNameCopy[0] = 'changed.example.com';
      expect(adapter.certificateDer()[0]).assertEqual(0x30);
      expect(adapter.subjectAlternativeNameExtension()[0]).assertEqual(0x04);
      expect(adapter.subjectCommonNames()[0]).assertEqual('db.example.com');

      const factory = new MockPeerCertificateFactory(
        peerWithSan(null, ['db.example.com']));
      const verifier = createDefaultPostgresTlsIdentityVerifier(factory);
      await verifier.verify(remoteCertificateFixture(), 'db.example.com');
      let terminal = await failure((): Promise<void> =>
        verifier.verify(remoteCertificateFixture(), 'wrong.example.com'));
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
      expect(terminal.nativeCode).assertEqual('TLS_HOSTNAME_MISMATCH');
      expect(terminal.message).assertEqual(
        'PostgreSQL TLS certificate does not match the requested host');
      const original = ArkDbError.tls(
        'Synthetic exact certificate failure', 'CERT_DECODE');
      factory.typedFailure = original;
      terminal = await failure((): Promise<void> =>
        verifier.verify(remoteCertificateFixture(), 'db.example.com'));
      expect(terminal === original).assertTrue();
      factory.typedFailure = null;
      factory.failure = new Error('Synthetic certificate decode failure');
      terminal = await failure((): Promise<void> =>
        verifier.verify(remoteCertificateFixture(), 'db.example.com'));
      expect(terminal.message).assertEqual(
        'Could not verify PostgreSQL TLS server identity: ' +
        'Synthetic certificate decode failure');
      factory.failure = new Error('Synthetic absent peer certificate');
      terminal = await failure((): Promise<void> =>
        verifier.verify(remoteCertificateFixture(), 'db.example.com'));
      expect(terminal.kind).assertEqual(ArkDbErrorKind.Tls);
      const malformedVerifier = createDefaultPostgresTlsIdentityVerifier(
        new MockPeerCertificateFactory(
          peerWithSan(element(0x04, element(0x30, new Uint8Array(0))),
            ['db.example.com'])));
      terminal = await failure((): Promise<void> =>
        malformedVerifier.verify(
          remoteCertificateFixture(), 'db.example.com'));
      expect(terminal.nativeCode).assertEqual(
        'TLS_CERTIFICATE_IDENTITY_INVALID');
    });
  });
}
class MockDecodedCertificate implements PostgresDecodedCertificate {
  private readonly entry: Uint8Array;
  private readonly commonNames: string[];
  constructor(entry: Uint8Array, commonNames: string[]) {
    this.entry = entry;
    this.commonNames = commonNames;
  }
  subjectAlternativeNameExtension(): Uint8Array {
    return this.entry;
  }
  subjectCommonNames(): string[] {
    return this.commonNames;
  }
}
class MockPeerCertificate implements PostgresPeerCertificate {
  private readonly encoded: Uint8Array;
  private readonly sanEntry: Uint8Array;
  private readonly commonNames: string[];
  constructor(encoded: Uint8Array, sanEntry: Uint8Array,
    commonNames: string[]) {
    this.encoded = encoded;
    this.sanEntry = sanEntry;
    this.commonNames = commonNames;
  }
  certificateDer(): Uint8Array { return this.encoded; }
  subjectAlternativeNameExtension(): Uint8Array { return this.sanEntry; }
  subjectCommonNames(): string[] { return this.commonNames; }
}
class MockPeerCertificateFactory implements PostgresPeerCertificateFactory {
  private readonly peer: PostgresPeerCertificate;
  typedFailure: ArkDbError | null = null;
  failure: Error | null = null;
  constructor(peer: PostgresPeerCertificate) { this.peer = peer; }
  async create(certificate: socket.X509CertRawData):
  Promise<PostgresPeerCertificate> {
    if (this.typedFailure !== null) throw this.typedFailure;
    if (this.failure !== null) throw this.failure;
    return this.peer;
  }
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
function peerWithNames(names: Uint8Array[],
  commonNames: string[]): MockPeerCertificate {
  return peerWithSan(sanEntry(names), commonNames);
}
function peerWithSan(entry: Uint8Array | null, commonNames: string[],
  otherExtensions: Uint8Array[] = []): MockPeerCertificate {
  const fields = tbsFields();
  const encodedExtensions = otherExtensions.slice();
  if (entry !== null) {
    encodedExtensions.push(certificateExtension(
      SUBJECT_ALTERNATIVE_NAME_OID, entry));
  }
  if (encodedExtensions.length > 0) {
    fields.push(extensions(concatenate(encodedExtensions)));
  }
  return new MockPeerCertificate(
    certificate(fields), entry === null ? new Uint8Array(0) : entry,
    commonNames);
}
function sanEntry(names: Uint8Array[]): Uint8Array {
  return element(0x04, element(0x30, concatenate(names)));
}
function generalName(tag: number, value: Uint8Array): Uint8Array {
  return element(tag, value);
}
function x400Extension(type: number, value: Uint8Array): Uint8Array {
  return x400Extensions([x400ExtensionAttribute(type, value)]);
}
function x400Extensions(attributes: Uint8Array[]): Uint8Array {
  return generalName(0xa3, concatenate([
    element(0x30, new Uint8Array(0)),
    element(0x31, concatenate(attributes))
  ]));
}
function x400ExtensionAttribute(
  type: number, value: Uint8Array): Uint8Array {
  return element(0x30, concatenate([
    element(0x80, bytes([type])), element(0xa1, value)
  ]));
}
function x400ExtensionValues(): Uint8Array[] {
  const pds = element(0x31, element(0x13, ascii('pds')));
  return [
    element(0x13, ascii('common')),
    element(0x14, ascii('common')),
    element(0x14, ascii('organization')),
    element(0x31, element(0x80, ascii('surname'))),
    element(0x30, element(0x14, ascii('unit'))),
    element(0x30, element(0x30, concatenate([
      element(0x14, ascii('type')), element(0x14, ascii('value'))
    ]))),
    element(0x13, ascii('pds')),
    element(0x13, ascii('US')),
    element(0x12, ascii('12345')),
    pds, pds, pds, pds, pds, pds,
    element(0x31, element(0x30,
      element(0x13, ascii('address')))),
    pds, pds, pds, pds, pds,
    element(0x30, element(0x80, ascii('12345'))),
    element(0x02, bytes([3]))
  ];
}
function kerberosOtherName(realm: Uint8Array): Uint8Array {
  return generalName(0xa0, concatenate([
    element(0x06, bytes([0x2b, 0x06, 0x01, 0x05, 0x02, 0x02])),
    element(0xa0, element(0x30, concatenate([
      element(0xa0, element(0x1b, realm)),
      element(0xa1, element(0x30, concatenate([
        element(0xa0, element(0x02, bytes([1]))),
        element(0xa1, element(0x30,
          element(0x1b, ascii('postgres'))))
      ])))
    ])))
  ]));
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
function assertIp(host: string, expected: number[]): void {
  const actual = postgresIpAddressBytes(host);
  expect(actual !== null).assertTrue();
  assertBytes(actual!, bytes(expected));
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
function syncFailure(operation: () => void): ArkDbError {
  let terminal: ArkDbError | null = null;
  try {
    operation();
  } catch (error) {
    terminal = error as ArkDbError;
  }
  expect(terminal instanceof ArkDbError).assertTrue();
  return terminal!;
}
function remoteCertificateFixture(): socket.X509CertRawData {
  return {
    encodingFormat: platformCert.EncodingFormat.FORMAT_DER,
    data: bytes([0x30, 0])
  };
}
