export const PROTOCOL_VERSION = 1
const AUDIO_MAGIC = [0x45, 0x58, 0x56, 0x32] as const // EXV2
const HEADER_BYTES = 24

export type AgentMode = 'auto' | '8b' | '27b'
export type ToolProfile = 'none' | 'web'
export interface ApproximateLocation {
  latitude: number
  longitude: number
}
export type SessionState =
  | 'new'
  | 'armed'
  | 'capturing'
  | 'thinking'
  | 'speaking'
  | 'follow_up'
  | 'closed'

export interface ControlMessage {
  protocol_version: number
  type: string
  [key: string]: unknown
}

export interface AudioFrame {
  kind: 1 | 2
  flags: number
  sequence: number
  timestampMs: number
  payload: Uint8Array
}

export function control(type: string, fields: Record<string, unknown> = {}): string {
  return JSON.stringify({ protocol_version: PROTOCOL_VERSION, type, ...fields })
}

export function parseControl(raw: string): ControlMessage {
  const value = JSON.parse(raw) as ControlMessage
  if (value.protocol_version !== PROTOCOL_VERSION || typeof value.type !== 'string') {
    throw new Error('Unsupported HomeBlend control message')
  }
  return value
}

export function packInputPcm(sequence: number, timestampMs: number, pcm: Uint8Array): ArrayBuffer {
  if (pcm.byteLength === 0 || pcm.byteLength > 65_536) {
    throw new Error('PCM frame must contain 1-65536 bytes')
  }
  const output = new ArrayBuffer(HEADER_BYTES + pcm.byteLength)
  const view = new DataView(output)
  AUDIO_MAGIC.forEach((value, index) => view.setUint8(index, value))
  view.setUint8(4, PROTOCOL_VERSION)
  view.setUint8(5, 1)
  view.setUint16(6, 0, false)
  view.setUint32(8, sequence, false)
  view.setBigUint64(12, BigInt(timestampMs), false)
  view.setUint32(20, pcm.byteLength, false)
  new Uint8Array(output, HEADER_BYTES).set(pcm)
  return output
}

export function unpackAudioFrame(value: ArrayBuffer): AudioFrame {
  if (value.byteLength < HEADER_BYTES) throw new Error('Audio frame is shorter than its header')
  const view = new DataView(value)
  AUDIO_MAGIC.forEach((expected, index) => {
    if (view.getUint8(index) !== expected) throw new Error('Audio frame magic is invalid')
  })
  if (view.getUint8(4) !== PROTOCOL_VERSION) throw new Error('Audio protocol version is unsupported')
  const kind = view.getUint8(5)
  if (kind !== 1 && kind !== 2) throw new Error('Audio frame kind is unsupported')
  const payloadSize = view.getUint32(20, false)
  if (payloadSize === 0 || value.byteLength !== HEADER_BYTES + payloadSize) {
    throw new Error('Audio frame length is invalid')
  }
  return {
    kind,
    flags: view.getUint16(6, false),
    sequence: view.getUint32(8, false),
    timestampMs: Number(view.getBigUint64(12, false)),
    payload: new Uint8Array(value, HEADER_BYTES, payloadSize),
  }
}
