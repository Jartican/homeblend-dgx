export async function completeAnthropic({ provider, profile, request }) {
  const system = request.messages.filter(({ role }) => role === 'system').map(({ content }) => content).join('\n\n');
  const messages = request.messages.filter(({ role }) => role !== 'system');
  const response = await fetch(`${provider.baseUrl}/messages`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': provider.apiKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: profile.model,
      system: system || undefined,
      messages,
      temperature: request.temperature ?? 0,
      max_tokens: request.maxOutputTokens ?? profile.maxOutputTokens,
    }),
    signal: request.signal,
  });

  if (!response.ok) throw new Error(`Anthropic returned ${response.status}: ${await response.text()}`);
  const payload = await response.json();
  return {
    text: payload.content?.filter(({ type }) => type === 'text').map(({ text }) => text).join('') ?? '',
    model: payload.model ?? profile.model,
    providerResponse: payload,
    usage: payload.usage,
  };
}
