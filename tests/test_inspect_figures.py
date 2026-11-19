"""Unit tests for the optional offline ONNX frame inspector (no weights needed)."""

import hashlib
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from tools import inspect_figures as inspector


class StubNetwork:
    def __init__(self, output):
        self.output = output
        self.input = None

    def setInput(self, tensor):
        self.input = tensor

    def forward(self):
        return self.output


class FigureInspectorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cv, cls.np = inspector.load_cv()

    def run_rows(self, *rows):
        pred = self.np.zeros((1, 5, 8400), dtype=self.np.float32)
        for i, row in enumerate(rows):
            pred[0, :, i] = row
        net = StubNetwork(pred)
        frame = self.np.zeros((720, 1280, 3), dtype=self.np.uint8)
        frame[:, :, :] = (10, 30, 200)
        result = inspector.detect_figures(net, frame, self.cv, self.np)
        return result, net.input

    def test_letterbox_roundtrip(self):
        result, tensor = self.run_rows((320, 320, 100, 80, 0.8))
        self.assertEqual(result, [{"x": 540, "y": 280, "w": 200, "h": 160, "score": 0.8}])
        self.assertEqual(tensor.shape, (1, 3, 640, 640))
        self.np.testing.assert_allclose(tensor[0, :, 0, 0], [114 / 255] * 3)
        self.np.testing.assert_allclose(tensor[0, :, 320, 320], self.np.array([200, 30, 10]) / 255)

    def test_filter_and_suppress_overlapping_boxes(self):
        result, _ = self.run_rows((320, 320, 100, 80, 0.8), (322, 322, 100, 80, 0.5),
                                  (450, 320, 20, 30, 0.24), (490, 320, 20, 30, 1.4),
                                  (float("nan"), 320, 20, 30, 0.8), (250, 320, 0, 20, 0.8))
        self.assertEqual([box["score"] for box in result], [0.8])

    def test_clip_bounds_and_empty_output(self):
        result, _ = self.run_rows((15, 150, 50, 60, 0.7), (500, 35, 20, 20, 0.9))
        self.assertEqual(result, [{"x": 0, "y": 0, "w": 80, "h": 80, "score": 0.7}])
        self.assertEqual(self.run_rows()[0], [])

    def test_unsupported_model_output(self):
        bad = StubNetwork(self.np.zeros((1, 6, 8400), dtype=self.np.float32))
        frame = self.np.zeros((360, 640, 3), dtype=self.np.uint8)
        with self.assertRaisesRegex(ValueError, "1,5,8400"):
            inspector.detect_figures(bad, frame, self.cv, self.np)

    def hint_fixture(self):
        frame = self.np.full((720, 1280, 3), 47, dtype=self.np.uint8)
        own = {"x": 468, "y": 347, "w": 171, "h": 372, "score": 0.81}
        ally = {"x": 441, "y": 240, "w": 31, "h": 69, "score": 0.46}
        other = {"x": 551, "y": 240, "w": 31, "h": 69, "score": 0.44}
        # A short cyan name and a downward white marker at a distance where
        # the older small cyan rectangle above the head misses the name.
        self.cv.fillConvexPoly(frame, self.np.array([(443, 215), (470, 215), (456, 230)]), (239, 239, 239))
        for x in (431, 438, 445, 452, 465, 472):
            frame[202:207, x:x + 3] = (209, 188, 39)
        return frame, [own, ally, other]

    def test_ally_own_and_unknown_keep_the_same_detection(self):
        frame, boxes = self.hint_fixture()
        for color in [(39, 39, 238), (240, 240, 240), (238, 215, 37)]:
            frame[356:365, 636:645] = color  # arbitrary constant center color, irrelevant to the hints
            hints = inspector.add_view_hints(frame, boxes, "third-person", self.cv, self.np)
            self.assertEqual([box["hint"] for box in hints], ["own-area", "ally-marker", "unclassified"])
            self.assertEqual(hints[1]["marker"], {"x": 443, "y": 215, "w": 28, "h": 16})
            self.assertEqual([{key: candidate[key] for key in box} for candidate, box in zip(hints, boxes)], boxes)
        self.assertTrue(all("hint" not in box for box in boxes))

    def test_requires_both_cues_and_a_downward_marker(self):
        frame, (_, ally, other) = self.hint_fixture()
        self.assertIsNone(inspector.marker_above(frame, other, self.cv, self.np))
        for change in ("no name", "no arrow", "flat bar", "up arrow"):
            candidate = frame.copy()
            if change == "no name":
                candidate[197:210] = 47
            else:
                candidate[212:233] = 47
                if change == "flat bar":
                    candidate[215:232, 443:471] = 239
                if change == "up arrow":
                    self.cv.fillConvexPoly(candidate, self.np.array([(456, 215), (443, 230), (470, 230)]), (239, 239, 239))
            with self.subTest(change=change):
                self.assertIsNone(inspector.marker_above(candidate, ally, self.cv, self.np))
        top = {**ally, "y": 0}
        self.assertIsNone(inspector.marker_above(frame, top, self.cv, self.np))

    def test_cyan_rim_of_white_flash_is_not_a_name(self):
        frame, (_, ally, _) = self.hint_fixture()
        # Keep the same white taper but replace the spaced cyan name with
        # a coloured band immediately touching it (one two-colour effect).
        flash = frame.copy()
        flash[197:210] = 47
        flash[212:215, 443:471] = (233, 195, 71)
        hint, = inspector.add_view_hints(flash, [ally], "scope", self.cv, self.np)
        self.assertEqual(hint, {**ally, "hint": "unclassified"})
        # Allow a stray cyan pixel in the gap when the higher band is present.
        frame[213, 452] = (209, 188, 39)
        hint, = inspector.add_view_hints(frame, [ally], "third-person", self.cv, self.np)
        self.assertEqual(hint["hint"], "ally-marker")

    def test_view_context_does_not_assume_self_or_enemy(self):
        frame, boxes = self.hint_fixture()
        for view in ("scope", "unknown"):
            hints = inspector.add_view_hints(frame, boxes, view, self.cv, self.np)
            self.assertEqual([box["hint"] for box in hints], ["unclassified", "ally-marker", "unclassified"])
        hints = inspector.add_view_hints(frame, boxes, "interface", self.cv, self.np)
        self.assertEqual([box["hint"] for box in hints], ["interface-view"] * 3)
        self.assertTrue(all("marker" not in box for box in hints))

    def test_top_down_diagnostic_bmp_and_no_overwrite(self):
        # Same top-down uncompressed BGRX format as FORMA Ctrl+F5, with alpha ignored.
        rows = bytes([1, 2, 3, 0xF0, 5, 6, 7, 0x80, 8, 9, 10, 0x50, 11, 12, 13, 0x00])
        header = struct.pack("<2sIHHI", b"BM", 54 + len(rows), 0, 0, 54)
        header += struct.pack("<IiiHHIIiiII", 40, 2, -2, 1, 32, 0, len(rows), 0, 0, 0, 0)
        with TemporaryDirectory() as folder:
            source = Path(folder) / "кадр.bmp"
            source.write_bytes(header + rows)
            frame = inspector.read_frame(source, self.cv, self.np)
            self.assertEqual(frame.tolist(), [[[1, 2, 3], [5, 6, 7]], [[8, 9, 10], [11, 12, 13]]])
            out = Path(folder) / "кадр-figures.png"
            inspector.write_preview(out, frame, [], self.cv)
            before = out.read_bytes()
            with self.assertRaises(FileExistsError):
                inspector.write_preview(out, frame, [], self.cv)
            self.assertEqual(out.read_bytes(), before)
            self.assertEqual(source.read_bytes(), header + rows)


class RuntimeNetworkTest(unittest.TestCase):
    def setUp(self):
        self.runtime = Mock()
        self.session = self.runtime.InferenceSession.return_value
        self.in_meta = SimpleNamespace(name="images", shape=[1, 3, 640, 640], type="tensor(float)")
        self.out_meta = SimpleNamespace(name="output", shape=[1, 5, 8400], type="tensor(float)")
        self.session.get_inputs.return_value = [self.in_meta]
        self.session.get_outputs.return_value = [self.out_meta]

    def test_cpu_session_uses_only_verified_bytes_and_known_tensors(self):
        payload = b"model bytes fixture"
        network = inspector.RuntimeNetwork(payload, self.runtime)
        options = self.runtime.SessionOptions.return_value
        self.runtime.InferenceSession.assert_called_once_with(payload, sess_options=options, providers=["CPUExecutionProvider"])
        self.assertEqual(options.intra_op_num_threads, 2)
        self.assertEqual(options.inter_op_num_threads, 1)
        self.assertIs(options.execution_mode, self.runtime.ExecutionMode.ORT_SEQUENTIAL)
        tensor, output = object(), object()
        self.session.run.return_value = [output]
        network.setInput(tensor)
        self.assertIs(network.forward(), output)
        self.session.run.assert_called_once_with(["output"], {"images": tensor})

    def test_wrong_model_signature_fails_before_inference(self):
        for inputs, outputs in [([], [self.out_meta]), ([self.in_meta], [self.out_meta, self.out_meta]),
                                ([SimpleNamespace(shape=[1, 3, 320, 320], type="tensor(float)")], [self.out_meta]),
                                ([self.in_meta], [SimpleNamespace(shape=[1, 6, 8400], type="tensor(float)")]),
                                ([self.in_meta], [SimpleNamespace(shape=[1, 5, 8400], type="tensor(float16)")])]:
            self.session.get_inputs.return_value = inputs
            self.session.get_outputs.return_value = outputs
            with self.assertRaisesRegex(ValueError, "1,5,8400"):
                inspector.RuntimeNetwork(b"fixture", self.runtime)
        self.session.run.assert_not_called()


class ModelIntegrityTest(unittest.TestCase):
    def test_hash_checks_exactly_the_bytes_to_parse(self):
        with TemporaryDirectory() as folder:
            model = Path(folder) / "example.onnx"
            data = b"fixture ONNX payload"
            digest = hashlib.sha256(data).hexdigest()
            model.write_bytes(data)
            self.assertEqual(inspector.verified_model(model, digest.upper()), data)
            with self.assertRaisesRegex(ValueError, "SHA-256 модели не совпал"):
                inspector.verified_model(model, None)
            model.write_bytes(data + b"x")
            with self.assertRaisesRegex(ValueError, "SHA-256 модели не совпал"):
                inspector.verified_model(model, digest)

    def test_reject_bad_hash_and_pickled_weights(self):
        with self.assertRaisesRegex(ValueError, r"\.onnx"):
            inspector.verified_model(Path("not_loaded.pt"), "0" * 64)
        with self.assertRaisesRegex(ValueError, "64"):
            inspector.verified_model(Path("not_loaded.onnx"), "0" * 65)


if __name__ == "__main__":
    unittest.main()
