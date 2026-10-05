"""Experimental C8855-01 USB reader; no manufacturer DLL is executed."""
import ctypes as C
import ctypes.util
import struct
import time

VID, PID, INTERFACE, OUT_EP, IN_EP = 0x0661, 0x1300, 0, 0x02, 0x81
GATES = {"100ms": (0x0C, .1), "200ms": (0x0D, .2),
         "500ms": (0x0E, .5), "1s": (0x0F, 1.0)}


class CounterError(Exception):
    pass


class Descriptor(C.Structure):
    _fields_ = [("length", C.c_uint8), ("type", C.c_uint8), ("usb", C.c_uint16),
                ("class_", C.c_uint8), ("subclass", C.c_uint8),
                ("protocol", C.c_uint8), ("packet", C.c_uint8),
                ("vid", C.c_uint16), ("pid", C.c_uint16), ("version", C.c_uint16),
                ("manufacturer", C.c_uint8), ("product", C.c_uint8),
                ("serial", C.c_uint8), ("configs", C.c_uint8)]


class USB:
    def __init__(self):
        try:
            import libusb_package
            path = libusb_package.get_library_path()
        except ImportError:
            path = ctypes.util.find_library("usb-1.0")
        if not path:
            raise CounterError("USBライブラリがありません。「カウンターを開く.command」から起動してください。")
        self.lib = C.CDLL(path)
        P = C.c_void_p
        declarations = {
            "init": (C.c_int, [C.POINTER(P)]),
            "exit": (None, [P]),
            "get_device_list": (C.c_ssize_t, [P, C.POINTER(C.POINTER(P))]),
            "free_device_list": (None, [C.POINTER(P), C.c_int]),
            "get_device_descriptor": (C.c_int, [P, C.POINTER(Descriptor)]),
            "get_bus_number": (C.c_uint8, [P]),
            "get_device_address": (C.c_uint8, [P]),
            "open": (C.c_int, [P, C.POINTER(P)]),
            "close": (None, [P]),
            "claim_interface": (C.c_int, [P, C.c_int]),
            "release_interface": (C.c_int, [P, C.c_int]),
            "bulk_transfer": (C.c_int, [P, C.c_uint8, C.POINTER(C.c_uint8),
                                       C.c_int, C.POINTER(C.c_int), C.c_uint]),
            "error_name": (C.c_char_p, [C.c_int]),
        }
        for name, (restype, args) in declarations.items():
            f = getattr(self.lib, "libusb_" + name)
            f.restype, f.argtypes = restype, args
        self.ctx, self.handle = P(), P()
        self.claimed = False
        self.check(self.lib.libusb_init(C.byref(self.ctx)))

    def check(self, code):
        if code < 0:
            name = self.lib.libusb_error_name(code).decode()
            raise CounterError("USB通信エラー: " + name)

    def devices(self, open_device=False):
        listing = C.POINTER(C.c_void_p)()
        n = self.lib.libusb_get_device_list(self.ctx, C.byref(listing))
        self.check(n)
        matches = []
        try:
            for i in range(n):
                desc = Descriptor()
                self.check(self.lib.libusb_get_device_descriptor(listing[i], C.byref(desc)))
                if (desc.vid, desc.pid) == (VID, PID):
                    matches.append((listing[i], {
                        "bus": self.lib.libusb_get_bus_number(listing[i]),
                        "address": self.lib.libusb_get_device_address(listing[i]),
                        "vid": f"{VID:04x}", "pid": f"{PID:04x}"}))
            if open_device:
                if len(matches) != 1:
                    raise CounterError("C8855-01を1台だけUSB接続してください。検出数: " + str(len(matches)))
                self.check(self.lib.libusb_open(matches[0][0], C.byref(self.handle)))
                self.check(self.lib.libusb_claim_interface(self.handle, INTERFACE))
                self.claimed = True
            return [m[1] for m in matches]
        finally:
            self.lib.libusb_free_device_list(listing, 1)

    def write(self, data):
        buf = (C.c_uint8 * len(data)).from_buffer_copy(data)
        transferred = C.c_int()
        self.check(self.lib.libusb_bulk_transfer(self.handle, OUT_EP, buf, len(data),
                                               C.byref(transferred), 1000))
        if transferred.value != len(data):
            raise CounterError("USB命令が途中までしか送れませんでした。測定を中止しました。")
        time.sleep(.005)  # Official DLL waits 5 ms after each command.

    def read(self, size, timeout_ms):
        buf = (C.c_uint8 * size)()
        transferred = C.c_int()
        self.check(self.lib.libusb_bulk_transfer(self.handle, IN_EP, buf, size,
                                               C.byref(transferred), timeout_ms))
        if transferred.value != size:
            raise CounterError(f"USBデータ長が不一致です ({transferred.value}/{size})。測定を中止しました。")
        return bytes(buf)

    def drain(self):
        # Discard stopped acquisition's remaining FIFO data, bounded in time.
        until = time.monotonic() + 2
        while time.monotonic() < until:
            buf, transferred = (C.c_uint8 * 64)(), C.c_int()
            code = self.lib.libusb_bulk_transfer(self.handle, IN_EP, buf, 64,
                                               C.byref(transferred), 50)
            if code == -7:  # timeout: FIFO is empty
                return
            self.check(code)
            if not transferred.value:
                return
        raise CounterError("停止後のUSBデータが残っています。カウンターを再接続してください。")

    def close(self):
        if self.handle:
            if self.claimed:
                self.lib.libusb_release_interface(self.handle, INTERFACE)
            self.lib.libusb_close(self.handle)
            self.handle = C.c_void_p()
        if self.ctx:
            self.lib.libusb_exit(self.ctx)
            self.ctx = C.c_void_p()


def setup_packet(gate):
    """Block transfer, one gate = four bytes; zero-fill unused bytes."""
    return bytes([1, GATES[gate][0], 1, 0, 4, 0, 0, 0])


def decode_count(data):
    if len(data) != 4:
        raise CounterError("カウントデータは4バイト必要です。")
    value = struct.unpack("<I", data)[0]
    if value == 0xFFFFFFFF:
        raise CounterError("カウンターが転送エラーを返しました。結果を通常のカウントとして扱わないでください。")
    return value


class Counter:
    def __init__(self, usb):
        self.usb, self.started = usb, False

    def start(self, gate):
        if gate not in GATES:
            raise CounterError("対応していない測定時間です。")
        self.usb.write(b"\x04")  # Stop an earlier session before discarding its FIFO.
        self.usb.drain()
        self.usb.write(b"\x07")  # Mandatory reset; no PMT power or output-port command.
        self.usb.write(setup_packet(gate))
        self.started = True  # Stop even if start transfer fails partway.
        self.usb.write(bytes([3, 0, 0, 0, 0, 0, 0, 0]))
        self.gate_seconds = GATES[gate][1]

    def read_count(self):
        timeout = max(1000, int(self.gate_seconds * 2000 + 1000))
        return decode_count(self.usb.read(4, timeout))

    def stop(self):
        if self.started:
            self.usb.write(b"\x04")
            self.usb.drain()
            self.started = False
