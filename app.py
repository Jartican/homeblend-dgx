import json
import os
import time
import urllib.error
import urllib.request

from dash import Dash, Input, Output, State, callback, dcc, html, no_update


OLLAMA_URL = os.getenv("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")
DEFAULT_MODEL = os.getenv("OLLAMA_CODE_MODEL", "qwen2.5-coder:3b")
SYSTEM_PROMPT = """You are a pragmatic coding assistant working on Exocortex.
Give concise, technically accurate answers. When asked to change code, explain the
smallest safe change first. Never claim that you ran a command or edited a file."""


def ollama_request(path, payload=None, timeout=180):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{OLLAMA_URL}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def available_models():
    try:
        payload = ollama_request("/api/tags", timeout=3)
        names = [model["name"] for model in payload.get("models", [])]
        return names or [DEFAULT_MODEL], True
    except (OSError, urllib.error.URLError, TimeoutError):
        return [DEFAULT_MODEL], False


initial_models, initial_online = available_models()
app = Dash(__name__, title="Local Model Lab", update_title="Thinking…")
server = app.server


def message_card(message):
    role = message["role"]
    return html.Article(
        [
            html.Div("You" if role == "user" else "Local model", className="message-label"),
            dcc.Markdown(message["content"], className="message-content"),
        ],
        className=f"message {role}",
    )


app.layout = html.Main(
    [
        dcc.Store(id="conversation", storage_type="local", data=[]),
        html.Header(
            [
                html.Div(
                    [
                        html.Div("EXOCORTEX / LOCAL INFERENCE", className="eyebrow"),
                        html.H1("Model Lab"),
                        html.P("A direct chat surface for testing local Ollama models."),
                    ]
                ),
                html.Div(
                    [
                        html.Span(className="status-dot", id="status-dot"),
                        html.Span("Ollama online" if initial_online else "Ollama offline", id="status-text"),
                    ],
                    className="status-pill",
                ),
            ],
            className="topbar",
        ),
        html.Section(
            [
                html.Aside(
                    [
                        html.Label("Active model", htmlFor="model-select"),
                        dcc.Dropdown(
                            id="model-select",
                            options=[{"label": name, "value": name} for name in initial_models],
                            value=DEFAULT_MODEL if DEFAULT_MODEL in initial_models else initial_models[0],
                            clearable=False,
                        ),
                        html.Div(
                            [html.Span("Endpoint"), html.Code(OLLAMA_URL)],
                            className="detail-row",
                        ),
                        html.Div(
                            [html.Span("Context strategy"), html.Strong("Focused / compact")],
                            className="detail-row",
                        ),
                        html.Button("Clear conversation", id="clear-button", n_clicks=0, className="quiet-button"),
                        html.P(
                            "Conversation history stays in this browser. Prompts are sent only to local Ollama.",
                            className="privacy-note",
                        ),
                    ],
                    className="sidebar",
                ),
                html.Div(
                    [
                        html.Div(id="chat-history", className="chat-history"),
                        html.Div(id="run-meta", className="run-meta"),
                        html.Div(
                            [
                                dcc.Textarea(
                                    id="prompt",
                                    placeholder="Ask the local model about code, architecture, or a focused task…",
                                    className="prompt",
                                ),
                                html.Button("Send", id="send-button", n_clicks=0, className="send-button"),
                            ],
                            className="composer",
                        ),
                    ],
                    className="chat-panel",
                ),
            ],
            className="workspace",
        ),
    ],
    className="app-shell",
)


@callback(Output("chat-history", "children"), Input("conversation", "data"))
def render_history(messages):
    if not messages:
        return html.Div(
            [
                html.Div("LOCAL", className="empty-kicker"),
                html.H2("Ready when you are."),
                html.P("Try: “Review the model gateway and identify the smallest useful next change.”"),
            ],
            className="empty-state",
        )
    return [message_card(message) for message in messages]


@callback(
    Output("conversation", "data"),
    Output("prompt", "value"),
    Output("run-meta", "children"),
    Output("status-text", "children"),
    Output("status-dot", "className"),
    Input("send-button", "n_clicks"),
    Input("clear-button", "n_clicks"),
    State("prompt", "value"),
    State("model-select", "value"),
    State("conversation", "data"),
    prevent_initial_call=True,
)
def handle_action(send_clicks, clear_clicks, prompt, model, messages):
    from dash import ctx

    if ctx.triggered_id == "clear-button":
        return [], "", "Conversation cleared", no_update, no_update
    if not prompt or not prompt.strip():
        return no_update, no_update, "Enter a message first", no_update, no_update

    history = list(messages or [])
    user_message = {"role": "user", "content": prompt.strip()}
    request_messages = [{"role": "system", "content": SYSTEM_PROMPT}, *history, user_message]
    started = time.perf_counter()

    try:
        payload = ollama_request(
            "/api/chat",
            {"model": model, "messages": request_messages, "stream": False, "options": {"temperature": 0}},
        )
        answer = payload["message"]["content"]
        elapsed = time.perf_counter() - started
        updated = [*history, user_message, {"role": "assistant", "content": answer}]
        token_count = payload.get("eval_count")
        speed = token_count / elapsed if token_count else None
        detail = f"{model} · {elapsed:.1f}s" + (f" · {speed:.1f} tokens/s" if speed else "")
        return updated, "", detail, "Ollama online", "status-dot"
    except Exception as error:
        elapsed = time.perf_counter() - started
        detail = f"Request failed after {elapsed:.1f}s: {error}"
        return history, no_update, detail, "Ollama unavailable", "status-dot offline"


if __name__ == "__main__":
    app.run(debug=False, host="127.0.0.1", port=int(os.getenv("PORT", "8050")))
