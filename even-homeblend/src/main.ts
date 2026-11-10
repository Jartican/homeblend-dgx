import {
  waitForEvenAppBridge,
  TextContainerProperty,
  CreateStartUpPageContainer,
  TextContainerUpgrade,
  OsEventTypeList,
  AudioInputSource,
  AppLocationAccuracy,
} from '@evenrealities/even_hub_sdk'
import type { AgentMode, ApproximateLocation, SessionState, ToolProfile } from './protocol'
import { VoiceClient } from './voice-client'
import { WakeListener, type WakeDetection } from './wake-listener'
import { mountUi, setAgent, setAnswer, setHelp, setStatus, setTranscript } from './ui'

const DEFAULT_GATEWAY = 'wss://voice-core.invalid/voice/v2/voice/realtime'
const CLIENT_VERSION = '0.2.1'
const GATEWAY_URL = (import.meta.env.VITE_VOICE_GATEWAY_URL as string | undefined) || DEFAULT_GATEWAY
const AGENTS: AgentMode[] = ['auto', '8b', '27b']
const AGENT_LABELS: Record<AgentMode, string> = {
  auto: 'HomeBlend Web Auto',
  '8b': 'HomeBlend Web Fast 8B',
  '27b': 'HomeBlend Web Quality 27B',
}
const TOOL_PROFILE: ToolProfile = 'web'

class PcmPlayer {
  private context: AudioContext | null = null
  private nextStart = 0
  private sampleRate = 24_000
  private channels = 1
  private generation = 0
  private sources = new Set<AudioBufferSourceNode>()

  async unlock() {
    this.context ??= new AudioContext()
    await this.context.resume()
  }

  begin(sampleRate: number, channels: number) {
    this.cancel()
    this.sampleRate = sampleRate
    this.channels = channels
    this.nextStart = this.context?.currentTime ?? 0
  }

  enqueue(pcm: Uint8Array) {
    if (!this.context) return
    const sampleCount = Math.floor(pcm.byteLength / 2)
    const frameCount = Math.floor(sampleCount / this.channels)
    const buffer = this.context.createBuffer(this.channels, frameCount, this.sampleRate)
    const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength)
    for (let frame = 0; frame < frameCount; frame += 1) {
      for (let channel = 0; channel < this.channels; channel += 1) {
        const sample = view.getInt16((frame * this.channels + channel) * 2, true)
        buffer.getChannelData(channel)[frame] = sample / 32_768
      }
    }
    const source = this.context.createBufferSource()
    source.buffer = buffer
    source.connect(this.context.destination)
    this.sources.add(source)
    source.addEventListener('ended', () => this.sources.delete(source), { once: true })
    const startsAt = Math.max(this.context.currentTime + 0.03, this.nextStart)
    source.start(startsAt)
    this.nextStart = startsAt + buffer.duration
  }

  afterDrain(callback: () => void) {
    const generation = this.generation
    const delayMs = this.context ? Math.max(0, (this.nextStart - this.context.currentTime) * 1000) : 0
    window.setTimeout(() => {
      if (generation === this.generation) callback()
    }, delayMs + 40)
  }

  cancel() {
    this.generation += 1
    for (const source of this.sources) {
      try { source.stop() } catch { /* source may already have ended */ }
    }
    this.sources.clear()
    this.nextStart = this.context?.currentTime ?? 0
  }
}

mountUi()
const bridge = await waitForEvenAppBridge()
const player = new PcmPlayer()
let agent = (localStorage.getItem('homeblend-agent-v2') as AgentMode | null) ?? '27b'
if (!AGENTS.includes(agent)) agent = 'auto'
let sessionState: SessionState = 'new'
let transcript = ''
let answer = ''
let glassContent = 'Connecting to HomeBlend…'
let renderTimer: number | null = null
let lastRender = ''
let microphoneOpen = false
const recentTurns: string[] = []
let historyIndex = -1

const display = new TextContainerProperty({
  xPosition: 0,
  yPosition: 0,
  width: 576,
  height: 288,
  borderWidth: 0,
  borderColor: 5,
  paddingLength: 4,
  containerID: 1,
  containerName: 'homeblend',
  content: glassContent,
  isEventCapture: 1,
})
await bridge.createStartUpPageContainer(
  new CreateStartUpPageContainer({ containerTotalNum: 1, textObject: [display] }),
)

function delay(ms: number): Promise<void> {
  return new Promise(resolve => window.setTimeout(resolve, ms))
}

async function getApproximatePhoneLocation(): Promise<ApproximateLocation | null> {
  try {
    const location = await bridge.getAppLocation({
      accuracy: AppLocationAccuracy.Low,
      timeoutMs: 5_000,
    })
    if (!location) return null
    // Weather does not need street-level location. Two decimals is roughly
    // one kilometre and is only retained for this running session.
    return {
      latitude: Math.round(location.latitude * 100) / 100,
      longitude: Math.round(location.longitude * 100) / 100,
    }
  } catch {
    return null
  }
}

async function setMicrophone(open: boolean): Promise<void> {
  if (open === microphoneOpen) return
  if (!open) {
    try { await bridge.audioControl(false) } catch { /* already closed */ }
    microphoneOpen = false
    return
  }

  // Dev Preview hot-reloads can leave the phone bridge holding the previous
  // audio session. Explicitly release it before opening the G2 microphone.
  try { await bridge.audioControl(false) } catch { /* reset best-effort */ }
  await delay(180)
  const started = await bridge.audioControl(true, AudioInputSource.Glasses)
  if (!started) throw new Error('The G2 microphone did not start')
  microphoneOpen = true
}

function routeLabel() {
  return AGENT_LABELS[agent]
}

function render(text: string) {
  glassContent = text.slice(-420)
  if (renderTimer !== null) return
  renderTimer = window.setTimeout(async () => {
    renderTimer = null
    if (lastRender === glassContent) return
    lastRender = glassContent
    try {
      await bridge.textContainerUpgrade(new TextContainerUpgrade({
        containerID: 1,
        containerName: 'homeblend',
        content: glassContent,
      }))
    } catch {
      // The Even bridge can reject a render while its page or audio session is
      // changing. A later state render will retry the latest content.
      lastRender = ''
    }
  }, 120)
}

function showRoute() {
  setAgent(routeLabel())
  render(`${routeLabel()} · v${CLIENT_VERSION}\n\nSay “Hey Gauss” or tap to speak\nScroll to change route`)
}

setHelp('Requesting optional coarse phone location…')
const approximateLocation = await getApproximatePhoneLocation()

let wakeListener: WakeListener
let wakeStarting = false
let wakeInlineCommand = false
let wakeAutoCapture = false
let pendingWakePcm: Uint8Array[] = []
let pendingWakeBytes = 0
let wakeSilenceTimer: number | null = null
let wakeMaxTimer: number | null = null

function clearWakeTimers() {
  if (wakeSilenceTimer !== null) window.clearTimeout(wakeSilenceTimer)
  if (wakeMaxTimer !== null) window.clearTimeout(wakeMaxTimer)
  wakeSilenceTimer = null
  wakeMaxTimer = null
}

function clearPendingWakeAudio() {
  pendingWakePcm = []
  pendingWakeBytes = 0
}

function queuePendingWakeAudio(pcm: Uint8Array) {
  const copy = new Uint8Array(pcm)
  pendingWakePcm.push(copy)
  pendingWakeBytes += copy.byteLength
  const maximum = 16_000 * 2 * 10
  while (pendingWakeBytes > maximum && pendingWakePcm.length > 1) {
    pendingWakeBytes -= pendingWakePcm.shift()!.byteLength
  }
}

function pcmHasSpeech(pcm: Uint8Array): boolean {
  if (pcm.byteLength < 2) return false
  const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength)
  let squares = 0
  let samples = 0
  for (let offset = 0; offset + 1 < pcm.byteLength; offset += 8) {
    const sample = view.getInt16(offset, true)
    squares += sample * sample
    samples += 1
  }
  return samples > 0 && Math.sqrt(squares / samples) >= 350
}

function submitCurrentTurn(): boolean {
  clearWakeTimers()
  wakeAutoCapture = false
  wakeInlineCommand = false
  if (!client.commitTurn()) return false
  sessionState = 'thinking'
  setStatus('thinking', 'Thinking')
  render(`${transcript || 'Transcribing…'}\n\nHomeBlend is thinking…`)
  void setMicrophone(false)
  return true
}

function scheduleWakeSilenceCommit() {
  if (!wakeAutoCapture) return
  if (wakeSilenceTimer !== null) window.clearTimeout(wakeSilenceTimer)
  wakeSilenceTimer = window.setTimeout(() => {
    if (sessionState === 'capturing' && wakeAutoCapture) submitCurrentTurn()
  }, wakeListener.getConfig().wake_silence_ms)
}

function beginWakeCaptureTimers() {
  clearWakeTimers()
  wakeMaxTimer = window.setTimeout(() => {
    if (sessionState === 'capturing' && wakeAutoCapture) submitCurrentTurn()
  }, wakeListener.getConfig().wake_command_max_ms)
  if (wakeInlineCommand) scheduleWakeSilenceCommit()
}

function handleWakeHeard(pcm: Uint8Array, result: WakeDetection) {
  if (sessionState !== 'armed' && sessionState !== 'follow_up') return
  wakeListener.stop(false)
  wakeStarting = true
  wakeInlineCommand = wakeListener.hasInlineCommand(result.transcript)
  clearPendingWakeAudio()
  queuePendingWakeAudio(pcm)
  setStatus('listening', 'Gauss heard')
  setTranscript(result.transcript || '')
  render(`${routeLabel()}\n\nGauss heard — listening…`)
  client.startWakeTurn(sessionState === 'follow_up')
}

function armWakeListener(followUp: boolean) {
  clearWakeTimers()
  wakeStarting = false
  wakeAutoCapture = false
  wakeInlineCommand = false
  clearPendingWakeAudio()
  wakeListener.start()
  void setMicrophone(true).catch(error => {
    wakeListener.stop()
    setStatus('error', 'Microphone unavailable')
    setAnswer((error as Error).message)
    render(`Microphone unavailable\n\n${(error as Error).message}\nExit and reopen HomeBlend`)
  })
  setStatus('ready', 'Gauss ready')
  if (followUp) render(`${answer.slice(-340)}\n\nSay “Hey Gauss” or tap for a follow-up`)
  else showRoute()
}

const client = new VoiceClient(GATEWAY_URL, agent, TOOL_PROFILE, approximateLocation, {
  onConnection(status) {
    if (status === 'connecting') {
      setStatus('connecting', 'Connecting')
      render('Connecting to private HomeBlend voice…')
    } else if (status === 'disconnected') {
      setStatus('error', 'Reconnecting')
      render('Private voice disconnected\nReconnecting…')
    }
  },
  onState(state) {
    sessionState = state
    if (state === 'armed') {
      armWakeListener(false)
    } else if (state === 'capturing') {
      wakeListener.stop(false)
      void setMicrophone(true).catch(error => {
        setStatus('error', 'Microphone unavailable')
        setAnswer((error as Error).message)
        render(`Microphone unavailable\n\n${(error as Error).message}\nExit and reopen HomeBlend`)
      })
      setStatus('listening', 'Listening')
      setTranscript('')
      setAnswer('')
      transcript = ''
      answer = ''
      historyIndex = -1
      if (wakeStarting) {
        wakeStarting = false
        wakeAutoCapture = true
        for (const pcm of pendingWakePcm) client.sendPcm(pcm)
        clearPendingWakeAudio()
        beginWakeCaptureTimers()
        render(`${routeLabel()}\n\nGauss heard — listening…\nPause to send automatically`)
      } else {
        wakeAutoCapture = false
        render(`${routeLabel()}\n\nListening…\nTap to send`)
      }
    } else if (state === 'thinking') {
      wakeListener.stop()
      clearWakeTimers()
      void setMicrophone(false)
      setStatus('thinking', 'Thinking')
      render(`${transcript || 'Transcribing…'}\n\nHomeBlend is thinking…`)
    } else if (state === 'speaking') {
      wakeListener.stop()
      setStatus('speaking', 'Speaking')
    } else if (state === 'follow_up') {
      armWakeListener(true)
    }
  },
  onTranscript(text) {
    transcript = text
    setTranscript(text)
    render(`${text}\n\nHomeBlend is thinking…`)
  },
  onText(delta, done) {
    answer = done ? delta : answer + delta
    setAnswer(answer)
    if (done && answer.startsWith('You: ')) {
      if (recentTurns[0] !== answer) recentTurns.unshift(answer)
      recentTurns.splice(8)
      historyIndex = 0
      render(answer)
    }
  },
  onAudioStart(sampleRateHz, channels) { player.begin(sampleRateHz, channels) },
  onAudio(pcm) { player.enqueue(pcm) },
  onAudioDone() { player.afterDrain(() => client.playbackFinished()) },
  onAgent(model) {
    const locationStatus = approximateLocation ? 'coarse location is session-only' : 'location unavailable'
    setHelp(`v${CLIENT_VERSION} · “Hey Gauss” · ${model} · ${locationStatus} · content is memory-only`)
  },
  onError(message) {
    wakeListener.stop()
    clearWakeTimers()
    void setMicrophone(false)
    setStatus('error', 'Error')
    setAnswer(message)
    render(`HomeBlend error\n\n${message}`)
  },
})

setAgent(routeLabel())
wakeListener = new WakeListener(GATEWAY_URL, handleWakeHeard)
await wakeListener.loadConfig()
client.connect()

function cycleAgent(direction: 1 | -1) {
  if (sessionState !== 'armed') return
  const index = AGENTS.indexOf(agent)
  agent = AGENTS[(index + direction + AGENTS.length) % AGENTS.length]
  localStorage.setItem('homeblend-agent-v2', agent)
  setAgent(routeLabel())
  setStatus('connecting', 'Switching')
  wakeListener.stop()
  void setMicrophone(false)
  client.setRoute(agent, TOOL_PROFILE)
}

function handleScroll(direction: 1 | -1) {
  if (sessionState === 'follow_up' && recentTurns.length) {
    const nextIndex = Math.max(0, Math.min(recentTurns.length - 1, historyIndex + direction))
    historyIndex = nextIndex
    render(`${recentTurns[nextIndex].slice(-365)}\n\n${nextIndex + 1}/${recentTurns.length} · Tap follow-up`)
    return
  }
  cycleAgent(direction)
}

let lastTapAt = 0
function handleTap() {
  const now = Date.now()
  if (now - lastTapAt < 250) return
  lastTapAt = now

  if (sessionState === 'armed' || sessionState === 'follow_up') {
    wakeListener.stop()
    clearWakeTimers()
    wakeStarting = false
    wakeAutoCapture = false
    clearPendingWakeAudio()
    // AudioContext.resume() can hang in the Even phone WebView. Unlock is
    // best-effort and must never delay starting or submitting a G2 turn.
    void player.unlock().catch(() => {
      setHelp('Phone audio unavailable · text responses remain available')
    })
    client.startTurn(sessionState === 'follow_up')
  }
  else if (sessionState === 'capturing') {
    // Stop forwarding PCM and commit synchronously. Closing the bridge's
    // microphone is cleanup; waiting for it can swallow a tap on some phones.
    submitCurrentTurn()
  } else if (sessionState === 'thinking' || sessionState === 'speaking') {
    clearWakeTimers()
    player.cancel()
    client.bargeIn()
  }
}

function eventTypeOf(envelope?: { eventType?: OsEventTypeList }): OsEventTypeList | null {
  if (!envelope) return null
  return envelope.eventType ?? OsEventTypeList.CLICK_EVENT
}

let cleanedUp = false
function cleanup() {
  if (cleanedUp) return
  cleanedUp = true
  wakeListener.stop()
  clearWakeTimers()
  void setMicrophone(false)
  client.close()
  unsubscribe()
}

const unsubscribe = bridge.onEvenHubEvent(event => {
  const pcm = event.audioEvent?.audioPcm
  if (pcm) {
    if (wakeStarting && sessionState !== 'capturing') {
      queuePendingWakeAudio(pcm)
    } else if (sessionState === 'capturing') {
      client.sendPcm(pcm)
      if (wakeAutoCapture && pcmHasSpeech(pcm)) scheduleWakeSilenceCommit()
    } else if (sessionState === 'armed' || sessionState === 'follow_up') {
      wakeListener.push(pcm)
    }
  }
  const type = eventTypeOf(event.sysEvent) ?? eventTypeOf(event.textEvent)
  if (type === OsEventTypeList.DOUBLE_CLICK_EVENT) {
    void bridge.shutDownPageContainer(1)
  } else if (type === OsEventTypeList.CLICK_EVENT) {
    handleTap()
  } else if (type === OsEventTypeList.SCROLL_TOP_EVENT) {
    handleScroll(-1)
  } else if (type === OsEventTypeList.SCROLL_BOTTOM_EVENT) {
    handleScroll(1)
  } else if (type === OsEventTypeList.SYSTEM_EXIT_EVENT || type === OsEventTypeList.ABNORMAL_EXIT_EVENT) {
    cleanup()
  }
})

window.addEventListener('beforeunload', cleanup)
