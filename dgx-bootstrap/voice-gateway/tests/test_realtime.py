import asyncio
from io import BytesIO
import json
import sys
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from realtime_adapters import adapter_manifest
from realtime_core import SessionState, VoiceSession
from realtime_protocol import (
    AudioFrame,
    AudioKind,
    ProtocolError,
    control_message,
    pack_audio_frame,
    parse_control_message,
    unpack_audio_frame,
)
from realtime_pipeline import (
    BoundedConversation,
    PcmFormat,
    PcmTurnBuffer,
    PhraseBuffer,
    decode_wav_pcm,
    parse_sse_data_line,
)
from realtime_runtime import TurnCoordinator


class RealtimeProtocolTests(unittest.TestCase):
    def test_audio_frame_round_trip(self):
        frame = AudioFrame(AudioKind.INPUT_PCM, 7, 1234, b"\x00\x01" * 160)
        self.assertEqual(unpack_audio_frame(pack_audio_frame(frame)), frame)

    def test_audio_frame_rejects_corruption_and_oversize(self):
        frame = bytearray(pack_audio_frame(AudioFrame(AudioKind.INPUT_PCM, 1, 2, b"12")))
        frame[:4] = b"FAIL"
        with self.assertRaisesRegex(ProtocolError, "magic"):
            unpack_audio_frame(bytes(frame))
        with self.assertRaises(ProtocolError):
            pack_audio_frame(AudioFrame(AudioKind.INPUT_PCM, 1, 2, b"x" * 65_537))

    def test_control_messages_are_versioned_and_bounded(self):
        event = control_message("session.start", device="halo")
        self.assertEqual(parse_control_message(json.dumps(event)), event)
        with self.assertRaisesRegex(ProtocolError, "version"):
            parse_control_message('{"type":"session.start","protocol_version":2}')


class RealtimeSessionTests(unittest.TestCase):
    def make_speaking_session(self) -> VoiceSession:
        session = VoiceSession("session-1")
        session.handle(control_message("session.start", device="halo"), 0)
        session.handle(control_message("wake.detected", turn_id="turn-1"), 100)
        session.accept_audio(AudioFrame(AudioKind.INPUT_PCM, 0, 100, b"\0\0" * 160))
        session.handle(control_message("transcript.delta"), 250)
        session.handle(control_message("turn.commit"), 300)
        session.handle(control_message("transcript.delta", final=True), 350)
        session.handle(control_message("response.text.delta"), 600)
        session.handle(control_message("response.audio.started"), 900)
        return session

    def test_complete_halo_turn_and_latency_report(self):
        session = self.make_speaking_session()
        self.assertEqual(session.state, SessionState.SPEAKING)
        session.handle(control_message("playback.finished"), 1500)
        self.assertEqual(session.state, SessionState.FOLLOW_UP)
        report = session.trace.report()
        self.assertEqual(report["durations"]["speech_to_first_partial_transcript_ms"], 150)
        self.assertEqual(report["durations"]["commit_to_final_transcript_ms"], 50)
        self.assertEqual(report["durations"]["commit_to_first_audio_ms"], 600)
        self.assertTrue(report["passes"]["speech_to_first_partial_transcript_ms"])
        self.assertIsNone(report["passes"]["barge_in_cancel_ms"])
        session.handle(control_message("followup.timeout"), 9000)
        self.assertEqual(session.state, SessionState.ARMED)

    def test_wake_detected_starts_a_second_turn_during_followup(self):
        session = self.make_speaking_session()
        session.handle(control_message("playback.finished"), 1500)
        session.handle(control_message("wake.detected", turn_id="turn-2"), 1600)
        self.assertEqual(session.state, SessionState.CAPTURING)
        self.assertEqual(session.turn_id, "turn-2")
        self.assertEqual(session.audio_bytes_received, 0)

    def test_barge_in_returns_to_capture_and_tracks_cancel_latency(self):
        session = self.make_speaking_session()
        old_generation = session.generation
        session.handle(control_message("barge_in"), 1000)
        session.handle(control_message("response.cancelled"), 1075)
        self.assertEqual(session.state, SessionState.CAPTURING)
        self.assertGreater(session.generation, old_generation)
        self.assertEqual(session.trace.report()["durations"]["barge_in_cancel_ms"], 75)

    def test_text_may_continue_streaming_after_audio_starts(self):
        session = self.make_speaking_session()
        session.handle(control_message("response.text.delta"), 950)
        self.assertEqual(session.state, SessionState.SPEAKING)

    def test_new_turn_requires_followup_or_explicit_barge_in(self):
        session = self.make_speaking_session()
        with self.assertRaises(ProtocolError):
            session.handle(control_message("turn.start", turn_id="turn-2"), 950)

    def test_failed_turn_returns_to_armed_state(self):
        session = VoiceSession("session-failed")
        session.handle(control_message("session.start", device="browser"), 0)
        session.handle(control_message("turn.start", turn_id="turn-1"), 1)
        session.handle(control_message("turn.commit"), 2)
        session.handle(control_message("response.failed"), 3)
        self.assertEqual(session.state, SessionState.ARMED)

    def test_silent_turn_can_be_cancelled_without_inference(self):
        session = VoiceSession("session-cancel")
        session.handle(control_message("session.start", device="phone"), 0)
        session.handle(control_message("wake.detected", turn_id="turn-silent"), 1)
        session.accept_audio(AudioFrame(AudioKind.INPUT_PCM, 0, 0, b"\0\0" * 160))
        session.handle(control_message("turn.cancel"), 2)
        self.assertEqual(session.state, SessionState.ARMED)
        self.assertIsNone(session.turn_id)
        self.assertEqual(session.audio_bytes_received, 0)

    def test_inline_wake_text_turn_enters_thinking_without_audio(self):
        session = VoiceSession("session-text")
        session.handle(control_message("session.start", device="phone"), 0)
        session.handle(control_message(
            "text.turn",
            turn_id="turn-inline",
            text="Hey Gauss, activate translation.",
        ), 10)
        self.assertEqual(session.state, SessionState.THINKING)
        self.assertEqual(session.turn_id, "turn-inline")
        self.assertEqual(session.audio_bytes_received, 0)
        self.assertEqual(
            session.trace.report()["durations"]["commit_to_final_transcript_ms"],
            None,
        )

    def test_inline_text_turn_requires_armed_or_followup(self):
        session = VoiceSession("session-text-invalid")
        with self.assertRaises(ProtocolError):
            session.handle(control_message("text.turn", turn_id="turn-inline", text="hello"), 0)

    def test_audio_must_be_ordered_and_only_during_capture(self):
        session = VoiceSession("session-2")
        session.handle(control_message("session.start", device="g2"), 0)
        with self.assertRaisesRegex(ProtocolError, "capturing"):
            session.accept_audio(AudioFrame(AudioKind.INPUT_PCM, 0, 0, b"12"))
        session.handle(control_message("turn.start", turn_id="turn-1"), 1)
        session.accept_audio(AudioFrame(AudioKind.INPUT_PCM, 4, 20, b"12"))
        with self.assertRaisesRegex(ProtocolError, "sequence"):
            session.accept_audio(AudioFrame(AudioKind.INPUT_PCM, 4, 21, b"34"))

    def test_invalid_state_transition_fails_closed(self):
        session = VoiceSession("session-3")
        with self.assertRaises(ProtocolError):
            session.handle(control_message("response.audio.started"), 0)

    def test_device_adapters_preserve_output_constraints(self):
        self.assertEqual(adapter_manifest("halo").playback, "glasses")
        self.assertEqual(adapter_manifest("g2").playback, "phone")
        self.assertEqual(adapter_manifest("g2", external_audio_available=True).playback, "external_audio")
        self.assertEqual(adapter_manifest("browser").playback, "client")
        phone = adapter_manifest("phone")
        self.assertEqual(phone.playback, "client")
        self.assertTrue(phone.device.hardware_aec)
        self.assertEqual(phone.device.input_sample_rate_hz, 16_000)
        self.assertIn("no speaker", " ".join(adapter_manifest("g2").notes))


class TurnCoordinatorTests(unittest.TestCase):
    def test_new_work_cancels_the_previous_generation(self):
        async def scenario():
            started = asyncio.Event()
            cancelled = asyncio.Event()

            async def slow_work(_generation):
                started.set()
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    cancelled.set()
                    raise

            coordinator = TurnCoordinator()
            generation, task = await coordinator.start(slow_work)
            await asyncio.wait_for(started.wait(), timeout=2)
            self.assertTrue(coordinator.running)
            self.assertTrue(await asyncio.wait_for(coordinator.cancel(), timeout=2))
            self.assertTrue(cancelled.is_set())
            self.assertTrue(task.cancelled())
            self.assertTrue(coordinator.is_current(generation))

        asyncio.run(scenario())


class RealtimePipelineTests(unittest.TestCase):
    def test_pcm_turn_round_trips_through_wav_without_disk(self):
        audio_format = PcmFormat(16_000, 1)
        turn = PcmTurnBuffer(audio_format, max_bytes=64_000)
        turn.append(b"\x01\x02" * 1_600)
        self.assertEqual(turn.duration_ms, 100)
        decoded_format, payload = decode_wav_pcm(turn.wav_bytes())
        self.assertEqual(decoded_format, audio_format)
        self.assertEqual(payload, b"\x01\x02" * 1_600)

    def test_pcm_turn_is_aligned_and_bounded(self):
        turn = PcmTurnBuffer(PcmFormat(16_000, 2), max_bytes=3_200)
        with self.assertRaisesRegex(ProtocolError, "aligned"):
            turn.append(b"123")
        with self.assertRaisesRegex(ProtocolError, "limit"):
            turn.append(b"1234" * 801)

    def test_decode_wav_rejects_non_pcm_sample_width(self):
        destination = BytesIO()
        with wave.open(destination, "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(1)
            output.setframerate(8_000)
            output.writeframes(b"\0" * 80)
        with self.assertRaisesRegex(ValueError, "16-bit"):
            decode_wav_pcm(destination.getvalue())

    def test_phrase_buffer_releases_an_early_phrase_and_flushes_tail(self):
        phrases = PhraseBuffer(first_limit=40, later_limit=60)
        self.assertEqual(phrases.feed("This is an early complete sentence. More"), [
            "This is an early complete sentence."
        ])
        self.assertEqual(phrases.feed(" words arrive without punctuation until the configured boundary"), [
            "More words arrive without punctuation until the configured"
        ])
        self.assertEqual(phrases.flush(), ["boundary"])

    def test_sse_parser_extracts_only_data_events(self):
        self.assertIsNone(parse_sse_data_line(": keepalive"))
        self.assertIsNone(parse_sse_data_line("data: [DONE]"))
        self.assertEqual(
            parse_sse_data_line('data: {"type":"response.output_text.delta","delta":"hi"}'),
            {"type": "response.output_text.delta", "delta": "hi"},
        )

    def test_conversation_is_ephemeral_and_bounded(self):
        history = BoundedConversation(max_messages=2, max_characters=20)
        history.append_turn("one", "two")
        history.append_turn("three", "four")
        self.assertEqual(history.snapshot(), [
            {"role": "user", "content": "three"},
            {"role": "assistant", "content": "four"},
        ])


if __name__ == "__main__":
    unittest.main()
