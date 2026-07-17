# Android release signing certificate

The private upload key is stored only in the `qelg/hermes-chat` GitHub Actions secrets.

- Alias: `hermes-chat`
- Algorithm: 4096-bit RSA / SHA384withRSA
- Valid through: 2053-11-30
- SHA-256 fingerprint: `1A:7E:1B:0D:DE:6E:17:0E:2A:F9:5D:BE:75:91:8F:A7:95:F4:97:AA:71:9A:13:1A:72:35:E5:12:E2:DD:90:80`

The public certificate is committed as `upload-certificate.pem`. Never commit the `.jks` keystore or `key.properties`.
