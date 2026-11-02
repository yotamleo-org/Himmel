// Preloaded by ../bunfig.toml before every `bun test` file: no test run reaches the operator's
// real keyring, however it is started. A test that needs a keyring brings its own stub (./keyring-stub.ts)
// and clears this in its own env map.
process.env.HIMMEL_SECRETS_KEYRING = "off";
