import { loadModelConfig } from './config.mjs';
import { completeAnthropic } from './providers/anthropic.mjs';
import { completeOpenAiCompatible } from './providers/openai-compatible.mjs';

const adapters = {
  'openai-compatible': completeOpenAiCompatible,
  anthropic: completeAnthropic,
};

export async function createModelGateway(config) {
  config ??= await loadModelConfig();
  return {
    async complete(route = config.defaultRoute, request) {
      const profileName = config.routes[route];
      const profile = config.profiles[profileName];
      if (!profile) throw new Error(`Unknown model route: ${route}`);
      const provider = config.providers[profile.provider];
      const adapter = adapters[provider?.kind];
      if (!adapter) throw new Error(`Unsupported provider for profile: ${profileName}`);
      return adapter({ provider, profile, request });
    },
  };
}
