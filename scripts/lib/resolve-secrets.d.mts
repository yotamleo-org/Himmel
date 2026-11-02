export function resolveSecrets(root: string, names: string[], env?: Record<string, string | undefined>): Record<string, string>;
export function keyringUnlocked(root: string, env?: Record<string, string | undefined>): boolean;
export function testKeyringOff(env?: Record<string, string | undefined>, childOnly?: boolean): boolean;
export function putSecret(root: string, name: string, value: string, env?: Record<string, string | undefined>): boolean;
