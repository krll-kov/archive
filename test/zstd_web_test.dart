import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_constants.dart';
import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:archive/src/util/xxh64.dart';
import 'package:test/test.dart';

// This file deliberately avoids dart:io so that it can be run on the web
// targets as well as the VM, with `dart test -p chrome` or `-p node`. The bit
// container, the sequence row layout, the literal loops and XXH64 are all
// written twice and picked per platform, so a test that only ever ran on the
// VM would guard none of it.
//
// Vectors written by zstd 1.5.7. Each row is name, archive, which dictionary
// or -1 for none, and the length and CRC-32 of what it must decode to.

const _vectors = <List<Object>>[
  ['text-8-l19.zst', 'KLUv/SQIQQAAZXBzaWxvbiDye+hb', -1, 8, 4206782857],
  [
    'text-1k-l19.zst',
    'KLUv/WToAm0FABQCZGVsdGEgYWxwaGEgZ2FtbWEgZXBzaWxvbnplYnp6'
        'emV6Rqihd/3fMELCIKUHEZSElgAJvGICkQsSLEjqFgONQ/dFkqPCK9zk'
        'EARlbnSrWjFK2s9yT2FpChHFUu4LgXm6woO47CKB26c4ToOqNYIDefwu'
        'vPzgUmExJm6SCVNTUFBAP3ypt1jMN7f3rFMtiKOxEXPozGHv3le/0ZcU'
        'cgGXjO1c87aMqqcZBRCqnAj19w==',
    -1,
    1000,
    2004545584
  ],
  ['rle-1k-l19.zst', 'KLUv/WToAkUAAAh3AQDkKyAEqL9x+A==', -1, 1000, 2810990746],
  [
    'mix-1k-l1.zst',
    'KLUv/WToAmUJAIQHYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b1iemXsTOdwkkCn7oGl3NUoZXBz'
        'L6ZmWgKsJz1FQTnBkrx5+mJuLnWVxraD1ESI8yP/h3rwVTNHpVGaZ2Ft'
        'bWEgZXBze6iRLyiqR2E4IEIIqW0RRFnSwkySQvsbcWmSGY1mHMoS66IE'
        '4BVyB6LYzDpSRwHWNd076SQxQedc7Lj8tKNp/zD5mjhddbPbhYlt3Oj8'
        'sTqSGGtD7y7O2VXOH2yKuLhTNFdnfiAiNCTYlGagohV5bkXdg/daFoBu'
        'xuK3cQlVhd4w4qZ5DSaPBtlK0P5bkeaITgQxEUVChhhLg5OJOfwBMAIB'
        'joN9nRVeciokz7fUT3ECFRg9pNg=',
    -1,
    1000,
    1204304730
  ],
  [
    'mix-1k-nocheck.zst',
    'KLUv/WDoAgUJADQHYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b1heuxM53CSQKfugaXc1ShlcHMv'
        'pmZaAqwnPUVBOcGSvHn6YmJ6YW4udZXGtoPURIjzI/+HevBVM0elUZpi'
        'elaoUZcUlVMoDAcwQsPYmQcRIBRMQI2iqm7bbAaR78H55olkOatBazD9'
        'cdU7DM3GzUN7A+KIB3cqpVEZ/a8EkwIRl2ERSlLk4KDU+pQ2SFTS5b3b'
        'Cv+ieLUAaavHKYlacZfLS0E8GItU4wd/8FQVJA1pCtuPx1YIWLMaIZTk'
        'AzAg4slAeaBls2qj6hwLUpo83UFr94o31361ZRKktLdvh3t48qJc/HII'
        'LwVxVA==',
    -1,
    1000,
    1204304730
  ],
  [
    'mix-1k-l19.zst',
    'KLUv/WToAs0HAJQGYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b3sTOdwkkCn7oGl3NUoei+mZloC'
        'rCc9RUE5wZK8efpuLnWVxraD1ESI8yP/h3rwVTNHpVGaSaiBLygqp5Dl'
        'MESgFEN2EVAEBBEFhJySKNVSYzsFdOvMWHwWJQeDNy27jBjC8Yw7D9UH'
        'qjQCh9jQm0rZKi42VcCa6P1P+FHfc4/P0k4WQ2E6jBP5HT4gI5UYQj3/'
        'UwUKep0kbQAM3LMPVZhdsoLpa6SFRiUwamM1zrF3C1MwWlvme4BjPuEL'
        '1htGsc9QqBg9pNg=',
    -1,
    1000,
    1204304730
  ],
  [
    'web-dict-l3.zst',
    'KLUv/WfE3CYKtwUNCgADhw4hIyJAevxoy8lSh3mTPXy29MHSpTtESVnp'
        'as74hnckl5JFWcaXyaJg3bz7Vi1+rpqvxXw3Ed3UWloGgIT8ywOw7tS8'
        'h7eKQ0HC0hwUhjN2Sf9q89DcQ4GHav2U23Y3HB7P6jpS9FbfkAMFkSOM'
        'VdU1TOQlmzLNDikjGq8PcZqRDCSnGbiHbtuQ7Htshklfh8cUupQ9oGh6'
        'C1FqeZVzt3r0jAJ/I2w4axDsjX+EPLRliT2GvYUjK26JkOpuwZPqtNfV'
        'DRDCdKhP5CJkCkia6ummq2uMKsHxkeBwnAuerN5RKr03hru2o5i0y2Sk'
        'UGWNSiXoBXbm8bP89rVqYM2E8lUAaWxW2VeaLtRWGL1hFmMgkAagdy6r'
        'htHMCocj8r8peL/gbWPfoZT+CmPKjJgwwSIX96cAT36dDA+CRX7f0x4C'
        'UVYn',
    0,
    1719,
    1848633491
  ],
  [
    'web-dict-l19.zst',
    'KLUv/WfE3CYKtwVNCADjBg3WluswLSdbvOITW/oNlujSNQ0RZaWriTM+'
        '3smlRMnxYd28+1Ytfq6aly8y301EN7WWlkECZvxPudA4D16rHrHSjzeI'
        'j2psloKeCVZ4YFrtTh+yntq1VKzsrcScQauChuXF2IDaEcMz8fYo/3A0'
        'So/aXSxNMi9y6eo6CKJWyeOcKfOMCps2NFdDyVWBifkYsaUj38D14RZm'
        '0m8JJG0mxlcS6sdWT33VbKuSQqQH/sD9SJ5pen1KmcSfk1vV2hGDdpki'
        'Ba9sVCmjV/Gs0/2iP9rq4blMY1c2RVMpvYEDhkfxFHb5c5ZDV+ixswXh'
        'Rveuo9Cu4FM+MEMkZ3kJcPLPZGgQuUNGUWobAlFWJw==',
    0,
    1719,
    1848633491
  ],
  [
    'web-raw-l3.zst',
    'KLUv/WS3BQ0LAMJJHhqAJW7Qi0ZvRtdHN/8jA9PLpEwZJEpA37isYIKB'
        'Z1ZDRIs0tV6jJm48TiRLgqxkgMmulzA9tRcv8zhjGtFYNurjQy7CXmqt'
        'v1s21CIkZVfIL4W5mGc4fqt9fFg/SLjYqlFUO+XlZ8ehXqAgCuGVggkA'
        'QIip+cVoGF9mqFBHUhcDQMKVg+oBEsBQKIhKthjGgRdZRlba/w5LCXah'
        'gIY8AKUVnDIMGyKMwYzN6O/cbjR4RrDXdgq9tW6nw1O7YkW/1RkySxD/'
        'y665fQ0Vs7CHcFL2uAO1uKJcHUhh9tR7XMmKfk5KkumOEFknm0jqsu+R'
        'FJsgYGIy9Y+QvfIL5GnDhhDF3rHGhmjEisNEvYWCWGinhOx8MnAGJFOH'
        'haeqWTNgSIRQHV2C/GyBtsxI1PBRKx+QDAY7NSqZFqJuq9ecRjFgQpMc'
        'G4gvjGlJZn8JHcUOka/Im/ifolC6Ia1xsgVfAlFWJw==',
    1,
    1719,
    1848633491
  ],
  [
    'web-raw-l19.zst',
    'KLUv/WS3BYUJAAJJGxeATRsEAo+rAQTwlBFTk93tIPsjEQNVD8O/dCV3'
        'Dn39c563XzAOozzMxD8ukcdHzNYrHkJS1NirAQF1vZ/2PIzvdJHmBJxL'
        'tHbUIyD0aQoPm/j6blTTosvVhZKELUdxRKw5JGNYP1PMQShorwpQoDBH'
        'RmcMIERIiHPbAU+lA5qOx0KrDihiwLUPHYx9gJ4mGAs8OrQpwMcaj45d'
        'OxVlaY3iCIFb5W3gCgyew3EHz4RXcDm7HxM0iHvY4YsGSOYnIgWADkmy'
        'Dfi2Eo4tALXaPmQW7Atqn+7tkuTbj5Ecc6W/4T1DTKbQIC/NcBqoSFzc'
        '7Jj9ATcdxH5TmYEIR3hwIi3NLFc/gfKRBB2T3H5cm0NvQ+A5UUfmblK6'
        '+SpOj+/n40IzAlE+JPPBjJMqqgECUVYn',
    1,
    1719,
    1848633491
  ],
];

const _dictionaries = <String>[
  'N6Qw7MTcJgoeEOBBCsMB/////0sEoDWAAFj+r9lSpiSllNxDcTgsUwEA'
      'AAYES0nmqwsAAARgwIADCog4CXVUvMBIRBIRw0Awx3jIEAAMgKERAAAA'
      'AAAApNdhoIi6JAAAAAAAAAAAAAAAAAEAAAAEAAAACAAAAG9uIjogIm9m'
      'ZnNldCIsICJyZXN1bHQiOiA1MzM5LCAicmVnaW9uIjogImFtc3RlcmRh'
      'bSIsICJvayI6IHRydWV9CnsidmVyc2lvbiI6ICJjYWNoZSIsICJ1c2Vy'
      'X2lkIjogNzM3NSwgInJlZ2lvbiI6ICJzaW5nYXBvcmUiLCAib2siOiBm'
      'YWxzZX0KeyJzdGF0dXMiOiAiYnVja2V0IiwgInJlZ2lvbiI6IDIyNDAy'
      'LCAicmVnaW9uIjogImZyYW5rZnVydCIsICJvayI6IHRydWV9Cnsibm9k'
      'ZSI6ICJyZWdpb24iLCAicmVnaW9uIjogNzA4NzAsICJyZWdpb24iOiAi'
      'b3JlZ29uIiwgIm9rIjogdHJ1ZX0KeyJvZmZzZXQiOiAidXNlcl9pZCIs'
      'ICJwYXlsb2FkIjogMTE5MDAsICJyZWdpb24iOiAic2luZ2Fwb3JlIiwg'
      'Im9rIjogZmFsc2V9Cnsic2hhcmQiOiAib2Zmc2V0IiwgInNoYXJkIjog'
      'NTk3NjAsICJyZWdpb24iOiAic3lkbmV5IiwgIm9rIjogdHJ1ZX0KeyJl'
      'cnJvciI6ICJlcnJvciIsICJsYXRlbmN5IjogMTc0NTksICJyZWdpb24i'
      'OiAidmlyZ2luaWEiLCAib2siOiBmYWxzZX0KeyJyZXN1bHQiOiAibGF0'
      'ZW5jeSIsICJ0aW1lc3RhbXAiOiAyODQ3OCwgInJlZ2lvbiI6ICJ0b2t5'
      'byIsICJvayI6IGZhbHNlfQp7Im9mZnNldCI6ICJub2RlIiwgInZlcnNp'
      'b24iOiAzNDgyLCAicmVnaW9uIjogIm9yZWdvbiIsICJvayI6IGZhbHNl'
      'fQp7InJlZ2lvbiI6ICJzZXNzaW9uIiwgIm5vZGUiOiA2NTA0MywgInJl'
      'Z2lvbiI6ICJkdWJsaW4iLCAib2siOiB0cnVlfQp7InVzZXJfaWQiOiAi'
      'YnVja2V0IiwgInNlc3Npb24iOiA2MTg0NCwgInJlZ2lvbiI6ICJzeWRu'
      'ZXkiLCAib2siOiB0cnVlfQp7ImxhdGVuY3kiOiAibm9kZSIsICJ0aW1l'
      'c3RhbXAiOiAzNDU2MSwgInJlZ2lvbiI6ICJ2aXJnaW5pYSIsICJvayI6'
      'IGZhbHNlfQp7InRpbWVzdGFtcCI6ICJ2ZXJzaW9uIiwgInJldHJ5Ijog'
      'NDkzOTgsICJyZWdpb24iOg==',
  'eyJ1c2VyX2lkIjogInNoYXJkIiwgInJlc3VsdCI6IDk0OTQsICJyZWdp'
      'b24iOiAiZnJhbmtmdXJ0IiwgIm9rIjogZmFsc2V9CnsicmVzdWx0Ijog'
      'InJlZ2lvbiIsICJyZXN1bHQiOiAxMTI2NSwgInJlZ2lvbiI6ICJkdWJs'
      'aW4iLCAib2siOiBmYWxzZX0KeyJwYXlsb2FkIjogImxhdGVuY3kiLCAi'
      'cGF5bG9hZCI6IDcyMjI2LCAicmVnaW9uIjogImR1YmxpbiIsICJvayI6'
      'IHRydWV9CnsidGltZXN0YW1wIjogImxhdGVuY3kiLCAicmVzdWx0Ijog'
      'NzU2NDIsICJyZWdpb24iOiAiZHVibGluIiwgIm9rIjogdHJ1ZX0KeyJs'
      'YXRlbmN5IjogInJlc3VsdCIsICJ1c2VyX2lkIjogMzc5NTksICJyZWdp'
      'b24iOiAiZHVibGluIiwgIm9rIjogdHJ1ZX0KeyJ0aW1lc3RhbXAiOiAi'
      'cmV0cnkiLCAic2Vzc2lvbiI6IDEzNQ==',
];

void main() {
  test('streamed matches survive wrapping a 1 KiB window on every backend', () {
    final encoded = base64Decode(
        'KLUv/QQAZAAAKGFiY2RlAQD4URUtTAAAEGVhAQD7K4AFTAAAEGRlAQD7K4AF'
        'TAAAEGNkAQD7K4AFTAAAEGJjAQD7K4AFTAAAEGFiAQD7K4AFTAAAEGVhAQD7'
        'K4AFTAAAEGRlAQD7K4AFTAAAEGNkAQD7K4AFTAAAEGJjAQD7K4AFTAAAEGFi'
        'AQD7K4AFTAAAEGVhAQD7K4AFTAAAEGRlAQD7K4AFTAAAEGNkAQD7K4AFRQAA'
        'CGIBAJQqIATVo9ya');
    final source = List<int>.generate(15000, (i) => 97 + i % 5);
    expect(ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true),
        source);
    final output = OutputMemoryStream();
    ZstdDecoder().decodeStream(InputMemoryStream(encoded), output,
        verify: true, throwOnError: true);
    expect(output.getBytes(), source);
  });

  test('highest bit handles every exact integer width', () {
    const native = bool.fromEnvironment('dart.library.isolate');
    final maximumBit = native ? 62 : 52;
    var power = 1;
    for (var bit = 0; bit <= maximumBit; bit++) {
      expect(zstdHighestBitFast(power), bit);
      if (bit > 0) {
        expect(zstdHighestBitFast(power - 1), bit - 1);
        expect(zstdHighestBitFast(power + 1), bit);
      }
      power *= 2;
    }
  });

  final dictionaries = [
    for (final d in _dictionaries) ZstdDictionary(base64.decode(d))
  ];

  for (final vector in _vectors) {
    final name = vector[0] as String;
    final bytes = base64.decode(vector[1] as String);
    final which = vector[2] as int;
    final length = vector[3] as int;
    final crc = vector[4] as int;

    test('$name decodes', () {
      final decoder = which < 0
          ? ZstdDecoder()
          : ZstdDecoder(dictionary: dictionaries[which]);
      final decoded =
          decoder.decodeBytes(bytes, verify: true, throwOnError: true);
      expect(decoded.length, length);
      expect(getCrc32(decoded), crc);
    });
  }

  test('a damaged byte is caught by the checksum', () {
    final bytes = Uint8List.fromList(base64.decode(_vectors[5][1] as String));
    bytes[bytes.length - 6] ^= 0x20;
    expect(
        () =>
            ZstdDecoder().decodeBytes(bytes, verify: true, throwOnError: true),
        throwsA(anything));
  });

  test('XXH64 matches the reference on this platform', () {
    final data = Uint8List(200);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 31 + 7) & 0xff;
    }
    final hash = Xxh64();
    hash.update(data, 0, data.length);
    expect(hash.digestHigh, 0x95d9a0c9);
    expect(hash.digestLow, 0x77b4b6fb);
  });
}
