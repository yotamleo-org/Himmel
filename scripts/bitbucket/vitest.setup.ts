// env.ts asks the secrets resolver when it is imported: keep every in-process test off the real keyring.
// The resolver rows in env.test.ts reach a stub through their own spawned environment.
process.env.HIMMEL_SECRETS_KEYRING = 'off';
