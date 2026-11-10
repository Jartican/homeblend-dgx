type Status = 'connecting' | 'ready' | 'listening' | 'thinking' | 'speaking' | 'error'

let statusEl: HTMLDivElement
let agentEl: HTMLSpanElement
let transcriptEl: HTMLDivElement
let answerEl: HTMLDivElement
let helpEl: HTMLDivElement

export function mountUi() {
  const app = document.querySelector<HTMLDivElement>('#app')!
  app.innerHTML = `
    <main class="panel">
      <header><h1>HomeBlend Voice</h1><div id="status" class="status status-connecting">Connecting</div></header>
      <div class="route">Route: <span id="agent">HomeBlend Auto</span></div>
      <section><label>You</label><div id="transcript" class="bubble muted">Say “Hey Gauss” or tap the glasses.</div></section>
      <section><label>Assistant</label><div id="answer" class="bubble">Ready when you are.</div></section>
      <div id="help" class="help">“Hey Gauss”: hands-free start · tap: start/send · scroll: route · double-tap: exit</div>
    </main>
  `
  statusEl = app.querySelector('#status')!
  agentEl = app.querySelector('#agent')!
  transcriptEl = app.querySelector('#transcript')!
  answerEl = app.querySelector('#answer')!
  helpEl = app.querySelector('#help')!
  injectStyles()
}

export function setStatus(kind: Status, text: string) {
  statusEl.className = `status status-${kind}`
  statusEl.textContent = text
}

export function setAgent(text: string) { agentEl.textContent = text }

export function setTranscript(text: string) {
  transcriptEl.textContent = text || 'Listening…'
  transcriptEl.classList.toggle('muted', !text)
}

export function setAnswer(text: string) { answerEl.textContent = text || 'Thinking…' }
export function setHelp(text: string) { helpEl.textContent = text }

function injectStyles() {
  const style = document.createElement('style')
  style.textContent = `
    :root { color-scheme: dark; }
    html, body { margin: 0; height: 100%; background: #171717; color: #eee;
      font: 16px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    #app { min-height: 100%; display: flex; }
    .panel { width: min(680px, 100%); margin: auto; padding: 22px; box-sizing: border-box; display: grid; gap: 14px; }
    header { display: flex; justify-content: space-between; align-items: center; }
    h1 { margin: 0; font-size: 20px; }
    .status { border: 1px solid #555; border-radius: 999px; padding: 4px 9px; font-size: 11px; text-transform: uppercase; }
    .status-ready { color: #3cfa44; border-color: #3cfa44; }
    .status-listening { color: #ffd60a; border-color: #ffd60a; }
    .status-thinking, .status-speaking { color: #64d2ff; border-color: #64d2ff; }
    .status-error { color: #ff453a; border-color: #ff453a; }
    .route, .help, label { color: #999; font-size: 12px; }
    .route span { color: #fff; }
    section { display: grid; gap: 5px; }
    .bubble { min-height: 52px; background: #292929; border: 1px solid #414141; border-radius: 12px; padding: 14px; white-space: pre-wrap; }
    .muted { color: #888; }
    .help { text-align: center; }
  `
  document.head.appendChild(style)
}
