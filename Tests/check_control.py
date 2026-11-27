import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "native", Path(__file__).resolve().parents[1] / "Scripts/tunnelguard-native.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
control = native.control


class EmergencyTest(unittest.TestCase):
    def test_pause_and_resume_do_not_reauthorize_an_old_proxy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.multiple(control, SUPPORT=root, STATE=root / "state", CODE_LOCK=root / "lock"):
                initial, _ = control.access_state()
                control.require_access(initial)
                with control.code_session():
                    self.assertTrue(control.code_active())
                self.assertFalse(control.code_active())
                control.set_access(True)
                with self.assertRaises(OSError):
                    control.require_access(initial)
                control.set_access(False)
                with self.assertRaises(OSError):
                    control.require_access(initial)
                current, _ = control.access_state()
                control.require_access(current)
                control.STATE.write_text("damaged")
                with self.assertRaises(OSError):
                    control.require_access(current)


    def test_panic_latches_before_desktop_stop_even_if_stop_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def confirm_latch():
                self.assertTrue(control.access_state()[1])
                raise OSError("synthetic failure")

            with patch.multiple(control, SUPPORT=root, STATE=root / "state"), \
                 patch.object(control, "stop_desktop", side_effect=confirm_latch):
                with self.assertRaises(OSError):
                    control.cli(native.guard, native.run, ["panic"])
                self.assertTrue(control.access_state()[1])
                with self.assertRaises(OSError):
                    control.cli(native.guard, native.run, ["launch-code", "--expected-egress", "8.8.8.8"])


if __name__ == "__main__":
    unittest.main()
