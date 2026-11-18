"""Shutdown must never interrupt protocol finalization or kill processes."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

source = Path(__file__).resolve().parents[1] / "tools/playback.py"
spec = importlib.util.spec_from_file_location("playback", source)
playback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(playback)


class RpcError(Exception):
    def code(self):
        return "FAILED_PRECONDITION"


class ShutdownTest(unittest.TestCase):
    def setUp(self):
        self.connection = Mock()
        position = Mock()
        position.connect.return_value = self.connection
        self.commands = Mock()
        self.pid = Mock(return_value=123)
        self.clock = Mock(side_effect=[0, 60, 120, 181])
        grpc = SimpleNamespace(RpcError=RpcError, StatusCode=SimpleNamespace(FAILED_PRECONDITION="FAILED_PRECONDITION"))
        patches = [patch.object(playback, "position", return_value=position),
                   patch.object(playback, "owned_pid", self.pid),
                   patch.object(playback.subprocess, "run", self.commands),
                   patch.object(playback.time, "monotonic", self.clock),
                   patch.object(playback.time, "sleep"),
                   patch.object(playback.socket, "socket"),
                   patch.dict("sys.modules", {"grpc": grpc}),
                   patch.object(playback.os, "killpg", create=True)]
        for p in patches:
            mock = p.start()
            self.addCleanup(p.stop)
        self.kill = mock
        playback.socket.socket.return_value.__enter__.return_value.connect_ex.return_value = 0

    def test_busy_protocol_is_left_running(self):
        self.connection.protocol.get_current_protocol_run.return_value = SimpleNamespace(end_time=SimpleNamespace(seconds=0))
        with self.assertRaisesRegex(RuntimeError, "Protocol is still finishing"):
            playback.stop()
        self.commands.assert_not_called()
        self.kill.assert_not_called()

    def test_manager_closes_only_after_protocol_finishes(self):
        protocol = self.connection.protocol
        protocol.get_current_protocol_run.side_effect = [SimpleNamespace(end_time=SimpleNamespace(seconds=0)),
                                                       SimpleNamespace(end_time=SimpleNamespace(seconds=1))]
        self.clock.side_effect = [0, 1, 2, 3]
        # Initial identity check, then manager gone after its close request.
        self.pid.side_effect = [123, None, None]
        self.commands.side_effect = lambda *a, **kw: self.assertEqual(protocol.get_current_protocol_run.call_count, 2)
        playback.stop()
        self.commands.assert_called_once()
        self.kill.assert_not_called()

    def test_slow_manager_shutdown_is_not_forced(self):
        self.connection.protocol.stop_protocol.side_effect = RpcError()
        self.clock.side_effect = [0, 31]
        with self.assertRaisesRegex(RuntimeError, "no processes were forcibly terminated"):
            playback.stop()
        self.commands.assert_called_once()
        self.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
