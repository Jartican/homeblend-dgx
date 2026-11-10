import {
  type AgentMode,
  type ApproximateLocation,
  type ControlMessage,
  type SessionState,
  type ToolProfile,
  control,
  packInputPcm,
  parseControl,
  unpackAudioFrame,
} from './protocol'

const MAX_PCM_FRAME_BYTES = 65_536

interface VoiceClientCallbacks {
  onConnection(status: 'connecting' | 'connected' | 'disconnected'): void
  onState(state: SessionState): void
  onTranscript(text: string, final: boolean): void
  onText(delta: string, done: boolean): void
  onAudioStart(sampleRateHz: number, channels: number): void
  onAudio(pcm: Uint8Array): void
  onAudioDone(durationMs: number): void
  onAgent(model: string): void
  onError(message: string): void
}

function createTurnId(): string {
  const webCrypto = globalThis.crypto
  if (typeof webCrypto?.randomUUID === 'function') return webCrypto.randomUUID()

  const bytes = new Uint8Array(16)
  if (typeof webCrypto?.getRandomValues === 'function') {
    webCrypto.getRandomValues(bytes)
  } else {
    let seed = Date.now() ^ Math.floor(Math.random() * 0xffff_ffff)
    for (let index = 0; index < bytes.length; index += 1) {
      seed = (Math.imul(seed, 1_664_525) + 1_013_904_223) >>> 0
      bytes[index] = seed & 0xff
    }
  }

  // RFC 4122 version 4 / variant 1. The identifier is only used to correlate
  // a voice turn; it is not an authentication or security token.
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0'))
  return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10).join('')}`
}

export class VoiceClient {
  private socket: WebSocket | null = null
  private reconnectTimer: number | null = null
  private closed = false
  private epoch = 0
  private sequence = 0
  private sampleFramesSent = 0
  private state: SessionState = 'new'

  constructor(
    private readonly url: string,
    private agent: AgentMode,
    private toolProfile: ToolProfile,
    private readonly location: ApproximateLocation | null,
    private readonly callbacks: VoiceClientCallbacks,
  ) {}

  connect(): void {
    this.closed = false
    this.clearReconnect()
    this.callbacks.onConnection('connecting')
    const epoch = ++this.epoch
    const socket = new WebSocket(this.url)
    socket.binaryType = 'arraybuffer'
    this.socket = socket
    socket.addEventListener('open', () => {
      if (epoch === this.epoch) this.callbacks.onConnection('connected')
    })
    socket.addEventListener('message', event => {
      if (epoch !== this.epoch) return
      try {
        if (event.data instanceof ArrayBuffer) {
          const frame = unpackAudioFrame(event.data)
          if (frame.kind === 2) this.callbacks.onAudio(frame.payload)
          return
        }
        this.handleControl(parseControl(String(event.data)))
      } catch (error) {
        this.callbacks.onError((error as Error).message)
      }
    })
    socket.addEventListener('close', () => {
      if (epoch !== this.epoch) return
      this.state = 'new'
      this.callbacks.onConnection('disconnected')
      if (!this.closed) this.reconnectTimer = window.setTimeout(() => this.connect(), 1500)
    })
    socket.addEventListener('error', () => {
      if (epoch === this.epoch) this.callbacks.onError('Private voice gateway connection failed')
    })
  }

  setRoute(agent: AgentMode, toolProfile: ToolProfile): void {
    this.agent = agent
    this.toolProfile = toolProfile
    this.restart()
  }

  startTurn(followUp = false): void {
    this.sequence = 0
    this.sampleFramesSent = 0
    this.send(followUp ? 'speech.started' : 'turn.start', { turn_id: createTurnId() })
  }

  startWakeTurn(followUp = false): void {
    this.sequence = 0
    this.sampleFramesSent = 0
    this.send(followUp ? 'speech.started' : 'wake.detected', { turn_id: createTurnId() })
  }

  sendPcm(pcm: Uint8Array): void {
    if (this.state !== 'capturing' || this.socket?.readyState !== WebSocket.OPEN) return
    // Wake detection hands us a rolling pre-roll buffer that can be several
    // seconds long. Preserve it, but packetize it into bounded protocol frames
    // before forwarding it to the realtime gateway.
    for (let offset = 0; offset < pcm.byteLength; offset += MAX_PCM_FRAME_BYTES) {
      const chunk = pcm.subarray(offset, Math.min(offset + MAX_PCM_FRAME_BYTES, pcm.byteLength))
      const timestampMs = Math.round((1000 * this.sampleFramesSent) / 16_000)
      this.socket.send(packInputPcm(this.sequence++, timestampMs, chunk))
      this.sampleFramesSent += Math.floor(chunk.byteLength / 2)
    }
  }

  commitTurn(): boolean {
    if (this.state !== 'capturing' || this.socket?.readyState !== WebSocket.OPEN) return false
    // Disable PCM forwarding before the gateway acknowledges THINKING so
    // microphone-close latency cannot append audio after the commit.
    this.state = 'thinking'
    this.send('turn.commit')
    return true
  }

  bargeIn(): void {
    this.sequence = 0
    this.sampleFramesSent = 0
    this.send('barge_in')
  }

  playbackFinished(): void { this.send('playback.finished') }
  followupTimeout(): void { this.send('followup.timeout') }

  close(): void {
    this.closed = true
    this.clearReconnect()
    if (this.socket?.readyState === WebSocket.OPEN) this.send('session.close')
    this.socket?.close()
    this.socket = null
  }

  private restart(): void {
    this.clearReconnect()
    this.epoch += 1
    this.socket?.close()
    this.socket = null
    this.state = 'new'
    this.connect()
  }

  private handleControl(event: ControlMessage): void {
    switch (event.type) {
      case 'session.ready':
        this.send('session.start', {
          device: 'g2',
          model: this.agent,
          effort: this.agent === '27b' ? 3 : 1,
          tool_profile: this.toolProfile,
          voice: 'af_heart',
          ...(this.location ? { location: this.location } : {}),
        })
        return
      case 'session.state':
        this.state = String(event.state) as SessionState
        this.callbacks.onState(this.state)
        return
      case 'transcript.delta':
        this.callbacks.onTranscript(String(event.text ?? ''), Boolean(event.final))
        return
      case 'response.text.delta':
        this.callbacks.onText(String(event.delta ?? ''), false)
        if (event.model) this.callbacks.onAgent(String(event.model))
        return
      case 'response.text.done':
        this.callbacks.onText(String(event.text ?? ''), true)
        if (event.model) this.callbacks.onAgent(String(event.model))
        return
      case 'response.audio.started':
        this.callbacks.onAudioStart(Number(event.sample_rate_hz), Number(event.channels))
        return
      case 'response.audio.done':
        this.callbacks.onAudioDone(Number(event.duration_ms ?? 0))
        return
      case 'error':
        this.callbacks.onError(String(event.detail ?? event.code ?? 'Voice gateway error'))
        // The gateway sends its authoritative session.state immediately
        // before this error. Keep the socket and conversation history alive;
        // reconnecting here caused visible UI thrash after recoverable turns.
        return
    }
  }

  private send(type: string, fields: Record<string, unknown> = {}): void {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(control(type, fields))
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== null) window.clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
  }
}
