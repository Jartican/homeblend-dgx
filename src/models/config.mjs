import { readFile } from 'node:fs/promises';

const ENV_PATTERN = /\$\{([A-Z0-9_]+)(?::-([^}]*))?\}/g;

function expandEnvironment(value) {
  if (typeof value === 'string') {
    return value.replace(ENV_PATTERN, (_, name, fallback) => {
      return process.env[name] ?? fallback ?? `\${${name}}`;
    });
  }
  if (Array.isArray(value)) return value.map(expandEnvironment);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, expandEnvironment(item)]));
  }
  return value;
}

export async function loadModelConfig(url = new URL('../../config/models.json', import.meta.url)) {
  return expandEnvironment(JSON.parse(await readFile(url, 'utf8')));
}
