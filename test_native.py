"""Exercise the app's actual C bridge with mock USB; no device needed."""
import ctypes as C
import pathlib
import subprocess
import tempfile
import unittest


class NativeBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = pathlib.Path(__file__).resolve().parent
        tmp = pathlib.Path(cls.temp.name)
        cls.mockpath = str(tmp / 'mock.dylib')
        bridge = str(tmp / 'bridge.dylib')
        for source, target in [('mock_usb.c', cls.mockpath), ('USBBridge.c', bridge)]:
            subprocess.run(['xcrun', 'clang', '-dynamiclib', '-Wall', '-Wextra', '-Werror',
                            str(root / source), '-o', target], check=True)
        cls.mock = C.CDLL(cls.mockpath)
        cls.bridge = C.CDLL(bridge)
        b = cls.bridge
        b.c8855_open.restype = C.c_void_p
        b.c8855_open.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t]
        b.c8855_probe.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t]
        b.c8855_start.argtypes = [C.c_void_p, C.c_uint8, C.c_uint]
        b.c8855_read.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
        b.c8855_stop.argtypes = [C.c_void_p]
        b.c8855_close.argtypes = [C.c_void_p]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def open(self, mode=0):
        self.mock.mock_reset(mode)
        error = C.create_string_buffer(512)
        h = self.bridge.c8855_open(self.mockpath.encode(), error, len(error))
        self.assertTrue(h, error.value)
        self.addCleanup(self.bridge.c8855_close, h)
        return h

    def test_probe_no_commands(self):
        self.mock.mock_reset(0)
        error = C.create_string_buffer(512)
        self.assertEqual(self.bridge.c8855_probe(self.mockpath.encode(), error, len(error)), 1)
        self.assertEqual(self.mock.mock_writes(), 0)

    def test_commands_and_unsigned_decode(self):
        h = self.open()
        self.assertEqual(self.bridge.c8855_start(h, 15, 3000), 0)
        count = C.c_uint32()
        self.assertEqual(self.bridge.c8855_read(h, C.byref(count)), 0)
        self.assertEqual(count.value, 0x92345678)
        self.assertEqual(self.bridge.c8855_stop(h), 0)
        self.assertEqual([self.mock.mock_opcode(i) for i in range(self.mock.mock_writes())], [4,7,1,3,4])

    def test_short_read_sentinel_and_timeout(self):
        for mode in [1,2,4]:
            h = self.open(mode)
            self.assertEqual(self.bridge.c8855_start(h, 15, 3000), 0)
            self.assertEqual(self.bridge.c8855_read(h, C.byref(C.c_uint32())), -1)
            self.assertEqual(self.bridge.c8855_stop(h), 0)

    def test_stop_after_partial_start(self):
        h = self.open(3)
        self.assertEqual(self.bridge.c8855_start(h, 15, 3000), -1)
        self.assertEqual(self.bridge.c8855_stop(h), 0)
        self.assertEqual(self.mock.mock_opcode(self.mock.mock_writes()-1), 4)

    def test_invalid_gate_no_commands(self):
        h = self.open()
        self.assertEqual(self.bridge.c8855_start(h, 2, 3000), -1)
        self.assertEqual(self.mock.mock_writes(), 0)
