export async function completeOpenAiCompatible({ provider, profile, request }) {
  const response = await fetch(`${provider.baseUrl}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${provider.apiKey}`,
    },
    body: JSON.stringify({
      model: profile.model,
      messages: request.messages,
      temperature: request.temperature ?? 0,
      max_tokens: request.maxOutputTokens ?? profile.maxOutputTokens,
      response_format: request.responseFormat,
      tools: request.tools,
    }),
    signal: request.signal,
  });

  if (!response.ok) throw new Error(`Model provider returned ${response.status}: ${await response.text()}`);
  const payload = await response.json();
  return {
    text: payload.choices?.[0]?.message?.content ?? '',
    model: payload.model ?? profile.model,
    providerResponse: payload,
    usage: payload.usage,
  };
}
