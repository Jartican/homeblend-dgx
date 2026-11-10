export interface WakeConfig {
  wake_word: string
  wake_aliases: string[]
  wake_clip_ms: number
  wake_command_max_ms: number
  wake_silence_ms: number
}

export interface WakeDetection {
  heard: boolean
  transcript?: string
  raw_audio_persisted?: boolean
}

const SAMPLE_RATE = 16_000
const CHANNELS = 1
const BYTES_PER_SAMPLE = 2

const DEFAULT_CONFIG: WakeConfig = {
  wake_word: 'Gauss',
  wake_aliases: ['gauss', 'gaus', 'goss', 'gouse', 'gauze'],
  wake_clip_ms: 1_600,
  wake_command_max_ms: 10_000,
  wake_silence_ms: 1_200,
}

function randomSessionId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') return globalThis.crypto.randomUUID()
  return `wake-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function endpointFromGateway(gatewayUrl: string, endpoint: string): string {
  const url = new URL(gatewayUrl)
  url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:'
  const realtimeSuffix = '/v2/voice/realtime'
  url.pathname = url.pathname.endsWith(realtimeSuffix)
    ? url.pathname.slice(0, -realtimeSuffix.length) + endpoint
    : endpoint
  url.search = ''
  url.hash = ''
  return url.toString()
}

function wavBlob(pcm: Uint8Array): Blob {
  const headerBytes = 44
  const wav = new Uint8Array(headerBytes + pcm.byteLength)
  const view = new DataView(wav.buffer)
  const ascii = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index += 1) wav[offset + index] = value.charCodeAt(index)
  }
  ascii(0, 'RIFF')
  view.setUint32(4, 36 + pcm.byteLength, true)
  ascii(8, 'WAVE')
  ascii(12, 'fmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, CHANNELS, true)
  view.setUint32(24, SAMPLE_RATE, true)
  view.setUint32(28, SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE, true)
  view.setUint16(32, CHANNELS * BYTES_PER_SAMPLE, true)
  view.setUint16(34, BYTES_PER_SAMPLE * 8, true)
  ascii(36, 'data')
  view.setUint32(40, pcm.byteLength, true)
  wav.set(pcm, headerBytes)
  return new Blob([wav], { type: 'audio/wav' })
}

export class WakeListener {
  private config: WakeConfig = DEFAULT_CONFIG
  private chunks: Uint8Array[] = []
  private totalBytes = 0
  private bytesSinceCheck = 0
  private enabled = false
  private inFlight = false
  private generation = 0
  private readonly sessionId = randomSessionId()
  private readonly configUrl: string
  private readonly wakeUrl: string

  constructor(
    gatewayUrl: string,
    private readonly onHeard: (pcm: Uint8Array, result: WakeDetection) => void,
  ) {
    this.configUrl = endpointFromGateway(gatewayUrl, '/v1/voice/config')
    this.wakeUrl = endpointFromGateway(gatewayUrl, '/v1/voice/wake')
  }

  async loadConfig(): Promise<WakeConfig> {
    try {
      const response = await fetch(this.configUrl, { cache: 'no-store', credentials: 'omit' })
      if (!response.ok) return this.config
      const value = await response.json() as Partial<WakeConfig>
      this.config = {
        wake_word: String(value.wake_word || DEFAULT_CONFIG.wake_word),
        wake_aliases: Array.isArray(value.wake_aliases)
          ? value.wake_aliases.map(alias => String(alias).toLowerCase())
          : DEFAULT_CONFIG.wake_aliases,
        wake_clip_ms: Math.max(1_000, Number(value.wake_clip_ms) || DEFAULT_CONFIG.wake_clip_ms),
        wake_command_max_ms: Math.max(3_000, Number(value.wake_command_max_ms) || DEFAULT_CONFIG.wake_command_max_ms),
        wake_silence_ms: Math.max(500, Number(value.wake_silence_ms) || DEFAULT_CONFIG.wake_silence_ms),
      }
    } catch {
      // The manual tap flow remains available when wake configuration is unavailable.
    }
    return this.config
  }

  getConfig(): WakeConfig { return this.config }

  start(): void {
    this.generation += 1
    this.enabled = true
    this.inFlight = false
    this.clearAudio()
  }

  stop(clearAudio = true): void {
    this.generation += 1
    this.enabled = false
    this.inFlight = false
    if (clearAudio) this.clearAudio()
  }

  push(pcm: Uint8Array): void {
    if (!this.enabled || pcm.byteLength === 0) return
    const copy = new Uint8Array(pcm)
    this.chunks.push(copy)
    this.totalBytes += copy.byteLength
    this.bytesSinceCheck += copy.byteLength
    this.trim()

    const clipBytes = Math.round(this.config.wake_clip_ms * SAMPLE_RATE * BYTES_PER_SAMPLE / 1_000)
    const hopBytes = Math.max(1, Math.floor(clipBytes / 2))
    if (!this.inFlight && this.totalBytes >= clipBytes && this.bytesSinceCheck >= hopBytes) {
      this.bytesSinceCheck = 0
      void this.detect(this.snapshot(clipBytes), this.generation)
    }
  }

  hasInlineCommand(transcript: string | undefined): boolean {
    if (!transcript) return false
    const aliases = [this.config.wake_word, ...this.config.wake_aliases]
      .map(value => value.toLowerCase().replace(/[^a-z0-9]/g, ''))
      .filter(Boolean)
    const words = transcript.toLowerCase().match(/[a-z0-9]+/g) ?? []
    if (!words.length) return false
    const first = words[0] === 'hey' ? words[1] : words[0]
    const remaining = words.slice(words[0] === 'hey' ? 2 : 1)
    return aliases.includes(first ?? '') && remaining.length > 0
  }

  private async detect(pcm: Uint8Array, generation: number): Promise<void> {
    this.inFlight = true
    try {
      const form = new FormData()
      form.append('session_id', this.sessionId)
      form.append('audio', wavBlob(pcm), 'g2-wake.wav')
      const response = await fetch(this.wakeUrl, {
        method: 'POST', body: form, cache: 'no-store', credentials: 'omit',
      })
      if (!response.ok) return
      const result = await response.json() as WakeDetection
      if (generation === this.generation && this.enabled && result.heard) {
        this.enabled = false
        // Forward only the clip that actually triggered detection. Replaying
        // the full rolling buffer duplicates old audio in STT and can create
        // oversized realtime frames.
        const clipBytes = Math.round(
          this.config.wake_clip_ms * SAMPLE_RATE * BYTES_PER_SAMPLE / 1_000,
        )
        this.onHeard(this.snapshot(clipBytes), result)
      }
    } catch {
      // Wake detection is optional; tap-to-speak remains usable during outages.
    } finally {
      if (generation === this.generation) this.inFlight = false
    }
  }

  private trim(): void {
    const maxBytes = Math.round(
      Math.max(this.config.wake_clip_ms * 3, 4_800) * SAMPLE_RATE * BYTES_PER_SAMPLE / 1_000,
    )
    while (this.totalBytes > maxBytes && this.chunks.length) {
      const excess = this.totalBytes - maxBytes
      const first = this.chunks[0]
      if (first.byteLength <= excess) {
        this.chunks.shift()
        this.totalBytes -= first.byteLength
      } else {
        this.chunks[0] = first.slice(excess)
        this.totalBytes -= excess
      }
    }
  }

  private snapshot(limitBytes = this.totalBytes): Uint8Array {
    const size = Math.min(limitBytes, this.totalBytes)
    const output = new Uint8Array(size)
    let writeAt = size
    for (let index = this.chunks.length - 1; index >= 0 && writeAt > 0; index -= 1) {
      const chunk = this.chunks[index]
      const count = Math.min(chunk.byteLength, writeAt)
      writeAt -= count
      output.set(chunk.subarray(chunk.byteLength - count), writeAt)
    }
    return output
  }

  private clearAudio(): void {
    this.chunks = []
    this.totalBytes = 0
    this.bytesSinceCheck = 0
  }
}
