export function resolveSecrets(root: string, names: string[]): Record<string, string>;
export function keyringUnlocked(root: string): boolean;
export function putSecret(root: string, name: string, value: string): boolean;
