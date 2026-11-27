"""A Windows pilot for one explicitly selected Claude Desktop executable."""

import csv
import ctypes
from ctypes import wintypes
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import queue
import socket
import ssl
import struct
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

if getattr(sys, "frozen", False):
    import tunnelguard_runner as guard
    RESOURCES = Path(sys._MEIPASS)
else:
    RESOURCES = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "tunnelguard_runner", RESOURCES.parent / "Scripts/tunnelguard-run.py")
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)

IP_UNICAST_IF = 31
NO_WINDOW = 0x08000000


class Firewall:
    def __init__(self, file):
        self.dll = ctypes.WinDLL(str(file))
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        pointer = ctypes.POINTER(wintypes.HANDLE)
        word = wintypes.LPWSTR
        number = wintypes.ULONG
        signatures = {
            "lock": [word], "status": [word], "unlock": [],
            "allow": [word, ctypes.c_uint16, pointer], "close": [wintypes.HANDLE],
            "route": [word, ctypes.POINTER(number)],
            "interface": [number, ctypes.POINTER(ctypes.c_uint64)],
            "launch": [word, word, pointer],
        }
        for name, args in signatures.items():
            function = getattr(self.dll, "tg_" + name)
            function.argtypes = args
            function.restype = wintypes.DWORD
            setattr(self, name, function)

    @staticmethod
    def require(result, description):
        if result:
            raise OSError(f"{description} (Windows 0x{result:08X})")

    def route_index(self, address):
        result = wintypes.ULONG()
        self.require(self.route(str(address), ctypes.byref(result)), "Маршрут IPv4 недоступен")
        return result.value

    def interface_id(self, index):
        result = ctypes.c_uint64()
        self.require(self.interface(index, ctypes.byref(result)), "Интерфейс VPN недоступен")
        return result.value


class WindowsProxy:
    def __init__(self, firewall, index, expected):
        self.firewall = firewall
        self.index = index
        self.identity = firewall.interface_id(index)
        self.stopped = threading.Event()
        self.policy = guard.EgressPolicy([expected], access_check=self.require_active)

    def require_active(self):
        if self.stopped.is_set():
            raise OSError("Прокси остановлен")

    def tunnel(self):
        self.require_active()
        if self.firewall.interface_id(self.index) != self.identity:
            raise OSError("Интерфейс изменился")
        return self.identity, self.index

    def verify_route(self, address, expected):
        if address.version != 4 or self.tunnel() != expected or self.firewall.route_index(address) != self.index:
            raise OSError("Маршрут не совпадает с выбранным интерфейсом")

    def connect_bound(self, address, port, tunnel=None):
        tunnel = self.tunnel() if tunnel is None else tunnel
        self.verify_route(address, tunnel)
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            connection.settimeout(guard.TIMEOUT)
            connection.setsockopt(socket.IPPROTO_IP, IP_UNICAST_IF, struct.pack("!I", self.index))
            connection.connect((str(address), port))
            self.verify_route(address, tunnel)
        except BaseException:
            connection.close()
            raise
        return connection, tunnel

    def preflight(self):
        guard.v2pro_interface = self.tunnel
        guard.verify_route = self.verify_route
        guard.connect_bound = self.connect_bound
        self.policy.authorize(self.tunnel(), 4, ssl.create_default_context())


def configured_executable(value):
    path = Path(value).expanduser().resolve(strict=True)
    if not path.is_file() or path.name.casefold() != "claude.exe" or str(path).startswith("\\\\"):
        raise OSError("Укажи локальный исполняемый файл Claude.exe")
    return path


def ensure_closed(executable):
    result = subprocess.check_output(
        [str(Path(os.environ["SystemRoot"]) / "System32/tasklist.exe"),
         "/FI", f"IMAGENAME eq {executable.name}", "/FO", "CSV", "/NH"],
        creationflags=NO_WINDOW, timeout=8
    )
    entries = csv.reader(result.decode("oem", errors="replace").splitlines())
    if any(row and row[0].casefold() == executable.name.casefold() for row in entries):
        raise OSError("Закрой все окна и процессы Claude перед защищённым запуском")


class App(tk.Tk):
    def __init__(self, firewall):
        super().__init__()
        self.title("TunnelGuard · Windows Preview")
        self.geometry("605x410")
        self.resizable(False, False)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.firewall = firewall
        self.events = queue.Queue()
        self.busy = False
        self.stop = threading.Event()
        self.worker = None
        self.settings = Path(os.environ["LOCALAPPDATA"]) / "TunnelGuard/windows-preview.json"
        try:
            saved = json.loads(self.settings.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            saved = {}
        self.executable = tk.StringVar(value=saved.get("executable", ""))
        self.index = tk.StringVar(value=saved.get("interface", ""))
        self.expected = tk.StringVar(value=saved.get("ipv4", ""))
        self.status = tk.StringVar(value="Укажи Claude.exe, индекс VPN-интерфейса и разрешённый IPv4.")

        panel = ttk.Frame(self, padding=22)
        panel.pack(fill="both", expand=True)
        panel.columnconfigure(0, weight=1)
        ttk.Label(panel, text="TunnelGuard", font=("Segoe UI", 21, "bold")).grid(row=0, columnspan=2, sticky="w")
        ttk.Label(panel, text="Windows 11 x64 · тестовая версия", style="TLabel").grid(row=1, columnspan=2, sticky="w", pady=(0, 14))
        ttk.Label(panel, text="Выбранный файл Claude.exe").grid(row=2, columnspan=2, sticky="w")
        ttk.Entry(panel, textvariable=self.executable).grid(row=3, column=0, sticky="ew", pady=(3, 10))
        self.choose = ttk.Button(panel, text="Выбрать…", command=self.browse)
        self.choose.grid(row=3, column=1, padx=(8, 0), sticky="n")
        fields = ttk.Frame(panel)
        fields.grid(row=4, columnspan=2, sticky="ew")
        ttk.Label(fields, text="Индекс VPN-интерфейса").grid(row=0, column=0, sticky="w")
        ttk.Label(fields, text="Разрешённый IPv4 выхода").grid(row=0, column=1, sticky="w", padx=12)
        ttk.Entry(fields, textvariable=self.index, width=25).grid(row=1, column=0, sticky="w", pady=4)
        ttk.Entry(fields, textvariable=self.expected, width=25).grid(row=1, column=1, sticky="w", padx=12, pady=4)
        self.detect = ttk.Button(fields, text="Найти маршрут", command=self.detect_route)
        self.detect.grid(row=1, column=2, sticky="w")
        ttk.Label(panel, textvariable=self.status, wraplength=540, justify="left").grid(
            row=5, columnspan=2, sticky="w", pady=17)
        actions = ttk.Frame(panel)
        actions.grid(row=6, columnspan=2, sticky="w")
        self.launch = ttk.Button(actions, text="Проверить и запустить", command=self.start)
        self.launch.pack(side="left")
        self.lock = ttk.Button(actions, text="Блокировать сеть", command=self.block)
        self.lock.pack(side="left", padx=8)
        self.interrupt = ttk.Button(actions, text="Остановить", command=self.stop.set, state="disabled")
        self.interrupt.pack(side="left")
        self.unlock = ttk.Button(panel, text="Снять блокировку…", command=self.unblock)
        self.unlock.grid(row=7, columnspan=2, sticky="w", pady=10)
        self.after(100, self.poll)

    def browse(self):
        result = filedialog.askopenfilename(filetypes=[("Claude.exe", "Claude.exe"), ("EXE", "*.exe")])
        if result:
            self.executable.set(result)

    def detect_route(self):
        try:
            index = self.firewall.route_index(guard.DOH_ADDRESSES[0])
            self.index.set(str(index))
            self.status.set(f"Текущий маршрут: интерфейс {index}. Сверь его с адаптером VPN.")
        except OSError as error:
            self.status.set(str(error))

    def save(self, executable):
        self.settings.parent.mkdir(exist_ok=True)
        pending = self.settings.with_suffix(".tmp")
        pending.write_text(json.dumps(dict(executable=str(executable), interface=self.index.get(),
                                           ipv4=self.expected.get())), encoding="utf-8")
        pending.replace(self.settings)

    def block(self):
        try:
            executable = configured_executable(self.executable.get())
            self.firewall.require(self.firewall.lock(str(executable)), "Не удалось записать блокировку WFP")
            self.save(executable)
            self.status.set("Прямые соединения выбранного Claude.exe заблокированы.")
        except (OSError, RuntimeError) as error:
            self.status.set(str(error))

    def unblock(self):
        if self.busy or not messagebox.askyesno("TunnelGuard", "Разрешить прямые соединения для ранее выбранного файла?"):
            return
        try:
            self.firewall.require(self.firewall.unlock(), "Не удалось снять блокировку WFP")
            self.status.set("Блокировка снята. Прямые соединения снова возможны.")
        except OSError as error:
            self.status.set(str(error))

    def start(self):
        try:
            executable = configured_executable(self.executable.get())
            index = int(self.index.get())
            expected = ipaddress.IPv4Address(self.expected.get().strip())
            if index < 1 or index > 0xffffffff or not guard.public_address(expected):
                raise ValueError()
            self.firewall.require(self.firewall.lock(str(executable)), "Не удалось записать блокировку WFP")
            self.save(executable)
        except ValueError:
            self.status.set("Нужны индекс интерфейса и разрешённый публичный IPv4.")
            return
        except (OSError, RuntimeError) as error:
            self.status.set(str(error))
            return
        self.busy = True
        self.stop.clear()
        self.status.set("Выбранный файл заблокирован. Проверяю маршрут и IPv4…")
        for widget in (self.choose, self.detect, self.launch, self.lock, self.unlock):
            widget.configure(state="disabled")
        self.interrupt.configure(state="normal")
        profile = self.settings.parent / "PreviewProfile"
        self.worker = threading.Thread(target=self.session, args=(executable, index, expected, profile))
        self.worker.start()

    def session(self, executable, index, expected, profile):
        process = wintypes.HANDLE()
        permit = wintypes.HANDLE()
        vpn = None
        try:
            ensure_closed(executable)
            vpn = WindowsProxy(self.firewall, index, expected)
            vpn.preflight()
            with guard.proxy_server(vpn.policy) as server:
                try:
                    ensure_closed(executable)
                    if self.stop.is_set():
                        return
                    port = server.server_address[1]
                    self.firewall.require(self.firewall.allow(str(executable), port, ctypes.byref(permit)),
                                          "Не удалось разрешить единственный порт прокси")
                    args = [str(executable), f"--user-data-dir={profile}", f"--proxy-server=http://127.0.0.1:{port}",
                            "--proxy-bypass-list=<-loopback>", "--disable-quic",
                            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost"]
                    command = ctypes.create_unicode_buffer(subprocess.list2cmdline(args))
                    self.firewall.require(self.firewall.launch(str(executable), command, ctypes.byref(process)),
                                          "Claude не запустился под обычной учётной записью")
                    self.events.put(("status", "Проверка IPv4 прошла. Доступ выбранного файла только через локальный прокси."))
                    while not self.stop.wait(0.5):
                        if self.firewall.kernel.WaitForSingleObject(process, 0) != 0x102:
                            break
                        self.firewall.require(self.firewall.status(str(executable)), "Блокировка WFP исчезла")
                        vpn.verify_route(guard.DOH_ADDRESSES[0], vpn.tunnel())
                finally:
                    vpn.stopped.set()
                    if permit:
                        self.firewall.require(self.firewall.close(permit), "Не удалось закрыть разрешение WFP")
                        permit = wintypes.HANDLE()
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            self.events.put(("status", f"Сеанс остановлен. {error}" if isinstance(error, OSError) else "Сетевая проверка не пройдена."))
        else:
            self.events.put(("status", "Прокси выключен. Блокировка выбранного файла сохранена."))
        finally:
            if permit:
                self.firewall.close(permit)
            if process:
                self.firewall.kernel.CloseHandle(process)
            self.events.put(("finished", ""))

    def poll(self):
        while not self.events.empty():
            kind, text = self.events.get()
            if kind == "status":
                self.status.set(text)
            else:
                self.busy = False
                for widget in (self.choose, self.detect, self.launch, self.lock, self.unlock):
                    widget.configure(state="normal")
                self.interrupt.configure(state="disabled")
        self.after(100, self.poll)

    def close(self):
        self.stop.set()
        if self.busy:
            self.after(100, self.close)
        else:
            self.destroy()


def main():
    firewall = Firewall(RESOURCES / "tunnelguard_wfp.dll")
    app = App(firewall)
    if not ctypes.windll.shell32.IsUserAnAdmin():
        app.withdraw()
        messagebox.showerror("TunnelGuard", "Запусти TunnelGuard с правами администратора для настройки Windows Filtering Platform.")
        return
    firewall.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    firewall.kernel.CreateMutexW.restype = wintypes.HANDLE
    instance = firewall.kernel.CreateMutexW(None, False, "Local\\TunnelGuardWindowsPreview")
    if not instance or ctypes.get_last_error() == 183:
        if instance:
            firewall.kernel.CloseHandle(instance)
        app.withdraw()
        messagebox.showerror("TunnelGuard", "Закрой другие экземпляры TunnelGuard, затем попробуй снова.")
        return
    try:
        app.mainloop()
    finally:
        firewall.kernel.CloseHandle(instance)


if __name__ == "__main__":
    main()
