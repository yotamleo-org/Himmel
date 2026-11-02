// Preloaded by ../bunfig.toml before every `bun test` file run with scripts/config-ui as the cwd: the process
// pins HIMMEL_SECRETS_KEYRING=off. This is the first layer only: bun reads the bunfig of its cwd, and a child
// that builds its own environment (login.ts) does not inherit it. The layer that holds from any cwd is
// resolve-secrets.mjs, which turns the keyring off under NODE_ENV=test unless the env names a stub keyring.
// A test that needs a keyring brings a stub (./keyring-stub.ts).
process.env.HIMMEL_SECRETS_KEYRING = "off";
