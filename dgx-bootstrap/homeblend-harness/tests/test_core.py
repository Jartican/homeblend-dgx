import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import ReadOnlyRepoTools, ToolLoop, chat_completion_payload, compose_messages, extract_market_entity, extract_market_symbol, extract_weather_location, format_weather, normalize_xml_tool_calls, requires_fresh_web_lookup, responses_to_messages, schemas_for_profile, select_nasdaq_symbol, weather_request_kind


class ReadOnlyToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "hello.txt").write_text("alpha\nbeta\ngamma\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "hello.txt"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"],
            cwd=self.root, check=True,
        )
        self.tools = ReadOnlyRepoTools(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def test_read_file_is_line_bounded(self):
        self.assertEqual(self.tools.read_file({"path": "hello.txt", "start_line": 2, "max_lines": 1}), "2: beta")

    def test_paths_cannot_escape_or_follow_symlinks(self):
        with self.assertRaises(ValueError):
            self.tools.read_file({"path": "../secret"})

    def test_rg_and_git_are_read_only(self):
        self.assertIn("hello.txt:2:beta", self.tools.rg({"query": "beta"}))
        self.assertEqual(self.tools.git_status({}), "CLEAN")
        (self.root / "hello.txt").write_text("changed\n", encoding="utf-8")
        self.assertIn("-alpha", self.tools.git_diff({}))


class LoopTests(unittest.TestCase):
    def test_plain_chat_omits_tool_fields_rejected_by_local_runtimes(self):
        payload = chat_completion_payload("local", [{"role": "user", "content": "hi"}], [], 100)
        self.assertNotIn("tools", payload)
        self.assertNotIn("tool_choice", payload)
        self.assertNotIn("parallel_tool_calls", payload)

    def test_tool_chat_includes_tool_fields(self):
        schemas = schemas_for_profile("web")
        payload = chat_completion_payload("local", [], schemas, 100)
        self.assertEqual(payload["tools"], schemas)
        self.assertEqual(payload["tool_choice"], "auto")
        self.assertFalse(payload["parallel_tool_calls"])

    def test_changing_market_fact_requires_fresh_web(self):
        self.assertTrue(requires_fresh_web_lookup([
            {"role": "user", "content": "What is the stock price for Nvidia?"},
        ]))
        self.assertTrue(requires_fresh_web_lookup([
            {"role": "user", "content": "Look up the latest weather online"},
        ]))
        self.assertTrue(requires_fresh_web_lookup([
            {"role": "user", "content": "What's the weather in Chicago IL?"},
        ]))
        self.assertTrue(requires_fresh_web_lookup([
            {"role": "user", "content": "What's the weather outside?"},
        ]))
        self.assertFalse(requires_fresh_web_lookup([
            {"role": "user", "content": "Explain dollar-cost averaging"},
        ]))

    def test_explicit_market_ticker_is_extracted(self):
        self.assertEqual(
            extract_market_symbol([
                {"role": "user", "content": "What is the current ETF price for EMXC?"},
            ]),
            ("EMXC", "etf"),
        )
        self.assertEqual(
            extract_market_symbol([
                {"role": "user", "content": "Give me the stock quote for NVDA"},
            ]),
            ("NVDA", "stocks"),
        )
        self.assertIsNone(extract_market_symbol([
            {"role": "user", "content": "What is the current stock price for SpaceX?"},
        ]))
        self.assertEqual(
            extract_market_symbol([
                {"role": "user", "content": "What is the price for ticker nvda?"},
            ]),
            ("NVDA", "stocks"),
        )

    def test_company_name_is_extracted_for_authoritative_ticker_resolution(self):
        messages = [{"role": "user", "content": "What is the current stock price for SpaceX?"}]
        self.assertIsNone(extract_market_symbol(messages))
        self.assertEqual(extract_market_entity(messages), ("SpaceX", "stocks"))

    def test_nasdaq_symbol_selection_prefers_exact_company_match(self):
        body = {"data": [
            {"symbol": "SPAX", "name": "Example Space Fund", "assetClass": "etf"},
            {"symbol": "SPCX", "name": "SpaceX", "assetClass": "stocks"},
        ]}
        self.assertEqual(select_nasdaq_symbol(body, "SpaceX", "stocks"), ("SPCX", "stocks"))
        self.assertIsNone(select_nasdaq_symbol({"data": [
            {"symbol": "LOFD", "name": "SpaceX Exposure Fund", "assetClass": "etf"},
        ]}, "SpaceX", "stocks"))

    def test_weather_location_is_named_or_relative(self):
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "What's the weather in Chicago IL?"},
        ]), "Chicago IL")
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "What is the weather in Chicago IL right now?"},
        ]), "Chicago IL")
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "What's the temperature in Chicago, IL today?"},
        ]), "Chicago, IL")
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "Is it supposed to rain today?"},
        ]), "")
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "What's the forecast for today?"},
        ]), "")
        self.assertEqual(extract_weather_location([
            {"role": "user", "content": "What's the weather outside?"},
        ]), "")
        self.assertIsNone(extract_weather_location([
            {"role": "user", "content": "Explain cloud formation"},
        ]))

    def test_rain_question_requests_precipitation_answer(self):
        self.assertEqual(weather_request_kind([
            {"role": "user", "content": "Is it supposed to rain today?"},
        ]), "precipitation")
        answer = format_weather({
            "location": "your approximate location",
            "temperature_unit": "°F",
            "today": {
                "condition": "partly cloudy",
                "temperature_max": 82,
                "temperature_min": 61,
                "precipitation_probability_max": 5,
                "precipitation_sum": 0,
                "precipitation_unit": "in",
            },
        }, "precipitation")
        self.assertIn("rain is not expected today", answer)
        self.assertIn("max chance 5%", answer)

    def test_responses_messages_are_converted_without_native_items(self):
        result = responses_to_messages({
            "instructions": "system",
            "input": [
                {"type": "additional_tools", "tools": []},
                {"role": "user", "content": [{"type": "input_text", "text": "hello"}]},
            ],
        })
        self.assertEqual(result, [{"role": "system", "content": "system"}, {"role": "user", "content": "hello"}])

    def test_system_instructions_are_collapsed_into_first_message(self):
        result = compose_messages("base", {
            "instructions": "client instructions",
            "input": [{"role": "system", "content": "history policy"}, {"role": "user", "content": "hello"}],
        })
        self.assertEqual([message["role"] for message in result], ["system", "user"])
        self.assertEqual(result[0]["content"], "base\nclient instructions\nhistory policy")

    def test_model_tool_model_loop(self):
        calls = []
        replies = iter([
            ({"role": "assistant", "content": None, "tool_calls": [{"id": "1", "function": {"name": "web_search", "arguments": json.dumps({"query": "answer"})}}]}, {"prompt_tokens": 10}),
            ({"role": "assistant", "content": "final"}, {"completion_tokens": 3}),
        ])
        loop = ToolLoop(lambda _messages, _tools: next(replies), lambda name, args: calls.append((name, args)) or "result")
        result = loop.run([{"role": "user", "content": "question"}])
        self.assertEqual(result.text, "final")
        self.assertEqual(result.tool_names, ["web_search"])
        self.assertEqual(result.usage["total_tokens"], 13)
        self.assertEqual(calls[0][1]["query"], "answer")

    def test_profiles_separate_web_from_repository_capabilities(self):
        self.assertEqual(
            [item["function"]["name"] for item in schemas_for_profile("web")],
            ["web_search", "market_quote", "fetch_url", "weather_current"],
        )
        self.assertNotIn("web_search", [item["function"]["name"] for item in schemas_for_profile("repo")])

    def test_model_cannot_call_tool_outside_profile(self):
        replies = iter([
            ({"role": "assistant", "content": None, "tool_calls": [{"id": "1", "function": {"name": "read_file", "arguments": "{}"}}]}, {}),
            ({"role": "assistant", "content": "denied"}, {}),
        ])
        called = []
        loop = ToolLoop(
            lambda _messages, _tools: next(replies),
            lambda name, args: called.append((name, args)) or "unsafe",
            schemas=schemas_for_profile("web"),
        )
        self.assertEqual(loop.run([{"role": "user", "content": "test"}]).text, "denied")
        self.assertEqual(called, [])

    def test_qwen_xml_tool_call_is_recovered(self):
        message = normalize_xml_tool_calls({
            "role": "assistant",
            "content": "thinking</think>\n<tool_call><function=read_file><parameter=path>README.md</parameter><parameter=max_lines>50</parameter></function></tool_call>",
            "tool_calls": [],
        })
        self.assertIsNone(message["content"])
        self.assertEqual(message["tool_calls"][0]["function"]["name"], "read_file")
        self.assertEqual(json.loads(message["tool_calls"][0]["function"]["arguments"])["max_lines"], 50)


if __name__ == "__main__":
    unittest.main()
