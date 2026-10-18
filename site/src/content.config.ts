import { defineCollection } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';
import { docsLoader } from './loaders/docs-loader.mjs';

export const collections = {
  docs: defineCollection({
    loader: docsLoader(new URL('../allowlist.txt', import.meta.url).pathname),
    schema: docsSchema(),
  }),
};
