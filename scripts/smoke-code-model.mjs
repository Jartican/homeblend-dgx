import { createModelGateway } from '../src/models/gateway.mjs';

const startedAt = performance.now();
const gateway = await createModelGateway();
const result = await gateway.complete('interactive-code', {
    temperature: 0,
    maxOutputTokens: 80,
    messages: [{
      role: 'user',
      content: 'Return only a JavaScript function named add that adds two numbers.',
    }],
});

console.log(result.text);
console.log(`\nmodel=${result.model} elapsed=${((performance.now() - startedAt) / 1000).toFixed(2)}s`);
