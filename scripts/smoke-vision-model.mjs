import { readFile } from 'node:fs/promises';
import { extname, resolve } from 'node:path';
import { createModelGateway } from '../src/models/gateway.mjs';

const imagePath = process.argv[2];
if (!imagePath) throw new Error('Usage: node scripts/smoke-vision-model.mjs <image-path>');

const mimeTypes = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };
const mimeType = mimeTypes[extname(imagePath).toLowerCase()];
if (!mimeType) throw new Error(`Unsupported image type: ${extname(imagePath)}`);

const image = await readFile(resolve(imagePath));
const gateway = await createModelGateway();
const startedAt = performance.now();
const result = await gateway.complete('interactive-vision', {
  maxOutputTokens: 200,
  messages: [{
    role: 'user',
    content: [
      { type: 'text', text: 'Briefly describe this image and transcribe any prominent text.' },
      { type: 'image_url', image_url: { url: `data:${mimeType};base64,${image.toString('base64')}` } },
    ],
  }],
});

console.log(result.text);
console.log(`\nmodel=${result.model} elapsed=${((performance.now() - startedAt) / 1000).toFixed(2)}s`);
