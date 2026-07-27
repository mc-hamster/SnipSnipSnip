#!/usr/bin/env python3
"""Validate a generated composition HTML file in an isolated real browser.

The validator uses only Python's standard library. It never opens an existing
browser profile, and the launched browser is configured to deny external
network access. Exit status 77 means that the requested browser is not
installed; all validation failures use exit status 1.
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import urlparse


SKIP_STATUS = 77
DEFAULT_TIMEOUT_SECONDS = 30.0

PROBE_EXPRESSION = r"""
(async () => {
  const waitForImages = Promise.all(
    Array.from(document.images).map((image) => {
      if (image.complete) return Promise.resolve();
      return new Promise((resolve) => {
        image.addEventListener("load", resolve, { once: true });
        image.addEventListener("error", resolve, { once: true });
      });
    })
  );
  await Promise.race([
    waitForImages,
    new Promise((resolve) => setTimeout(resolve, 5000))
  ]);

  const layout = document.querySelector("[data-step-layout]");
  const visibleSteps = () => Array.from(document.querySelectorAll("[data-step]"))
    .filter((step) => !step.hidden)
    .map((step) => Number(step.dataset.step));
  const status = () => document.querySelector("[data-step-status]")
    ?.textContent.trim() || "";

  const initialVisible = visibleSteps();
  const initialStatus = status();
  document.querySelector("[data-step-next]")?.click();
  await new Promise((resolve) => requestAnimationFrame(() => resolve()));
  const nextVisible = visibleSteps();
  const nextStatus = status();
  layout?.dispatchEvent(
    new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })
  );
  await new Promise((resolve) => requestAnimationFrame(() => resolve()));

  return JSON.stringify({
    protocol: location.protocol,
    enhanced: document.documentElement.classList.contains("is-enhanced"),
    csp: document.querySelector(
      'meta[http-equiv="Content-Security-Policy"]'
    )?.content || "",
    loadedImages: Array.from(document.images).every(
      (image) => image.complete && image.naturalWidth > 0 && image.naturalHeight > 0
    ),
    externalResources: performance.getEntriesByType("resource")
      .map((entry) => entry.name)
      .filter((url) => !/^(data|blob|file):/.test(url)),
    initialVisible,
    initialStatus,
    nextVisible,
    nextStatus,
    keyboardVisible: visibleSteps(),
    keyboardStatus: status(),
    currentStep: document.querySelector("[aria-current=step]")
      ?.textContent.trim() || "",
    previousDisabled: document.querySelector("[data-step-previous]")?.disabled,
    nextDisabled: document.querySelector("[data-step-next]")?.disabled,
    title: document.title
  });
})()
"""


class ValidationError(RuntimeError):
    pass


class WebSocket:
    def __init__(self, url: str, timeout: float) -> None:
        parsed = urlparse(url)
        if parsed.scheme != "ws" or not parsed.hostname or not parsed.port:
            raise ValidationError("unsupported WebSocket URL: {}".format(url))
        self._receive_buffer = bytearray()
        self._socket = socket.create_connection(
            (parsed.hostname, parsed.port),
            timeout=timeout,
        )
        try:
            self._socket.settimeout(timeout)
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            request = (
                "GET {} HTTP/1.1\r\n"
                "Host: {}:{}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Key: {}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).format(path, parsed.hostname, parsed.port, key)
            self._socket.sendall(request.encode("ascii"))
            response = self._read_http_headers()
            status_line = response.split(b"\r\n", 1)[0]
            if b" 101 " not in status_line:
                raise ValidationError(
                    "WebSocket handshake failed: {}".format(
                        status_line.decode("utf-8", errors="replace")
                    )
                )
            expected = base64.b64encode(
                hashlib.sha1(
                    (
                        key
                        + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                    ).encode("ascii")
                ).digest()
            ).decode("ascii")
            headers = {}
            for line in response.split(b"\r\n")[1:]:
                if b":" in line:
                    name, value = line.split(b":", 1)
                    headers[name.strip().lower()] = value.strip()
            actual = headers.get(b"sec-websocket-accept", b"").decode("ascii")
            if actual != expected:
                raise ValidationError(
                    "WebSocket server returned an invalid accept key"
                )
        except Exception:
            self._socket.close()
            raise

    def _read_http_headers(self) -> bytes:
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = self._socket.recv(4096)
            if not chunk:
                raise ValidationError("browser closed during WebSocket handshake")
            response.extend(chunk)
            if len(response) > 64 * 1024:
                raise ValidationError("oversized WebSocket handshake")
        headers, remainder = bytes(response).split(b"\r\n\r\n", 1)
        self._receive_buffer.extend(remainder)
        return headers + b"\r\n\r\n"

    def send_json(self, value: Dict[str, Any]) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
        first = 0x81
        length = len(payload)
        mask = os.urandom(4)
        if length < 126:
            header = bytes((first, 0x80 | length))
        elif length <= 0xFFFF:
            header = bytes((first, 0x80 | 126)) + struct.pack("!H", length)
        else:
            header = bytes((first, 0x80 | 127)) + struct.pack("!Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._socket.sendall(header + mask + masked)

    def receive_json(self) -> Dict[str, Any]:
        fragments = bytearray()
        while True:
            first, second = self._read_exact(2)
            final = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else b""
            payload = bytearray(self._read_exact(length))
            if masked:
                for index in range(len(payload)):
                    payload[index] ^= mask[index % 4]
            if opcode == 0x8:
                raise ValidationError("browser closed its debugging connection")
            if opcode == 0x9:
                self._send_control(0xA, bytes(payload))
                continue
            if opcode in (0x1, 0x0):
                fragments.extend(payload)
                if final:
                    try:
                        decoded = json.loads(fragments.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        raise ValidationError(
                            "browser returned invalid protocol JSON"
                        ) from error
                    if not isinstance(decoded, dict):
                        raise ValidationError(
                            "browser returned a non-object protocol message"
                        )
                    return decoded

    def _send_control(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._socket.sendall(
            bytes((0x80 | opcode, 0x80 | len(payload))) + mask + masked
        )

    def _read_exact(self, length: int) -> bytes:
        chunks = bytearray()
        buffered = min(length, len(self._receive_buffer))
        if buffered:
            chunks.extend(self._receive_buffer[:buffered])
            del self._receive_buffer[:buffered]
        while len(chunks) < length:
            chunk = self._socket.recv(length - len(chunks))
            if not chunk:
                raise ValidationError("browser closed its debugging connection")
            chunks.extend(chunk)
        return bytes(chunks)

    def close(self) -> None:
        try:
            self._send_control(0x8, b"")
        except OSError:
            pass
        self._socket.close()


class ProtocolClient:
    def __init__(self, websocket: WebSocket) -> None:
        self.websocket = websocket
        self.next_id = 1

    def request(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        session_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        message: Dict[str, Any] = {
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        if session_id:
            message["sessionId"] = session_id
        self.websocket.send_json(message)
        while True:
            response = self.websocket.receive_json()
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise ValidationError(
                    "{} failed: {}".format(method, json.dumps(response["error"]))
                )
            if response.get("type") == "error":
                raise ValidationError(
                    "{} failed: {}".format(method, json.dumps(response))
                )
            return response


def locate_browser(browser: str) -> Optional[Path]:
    environment_name = (
        "SSS_GOOGLE_CHROME_BINARY"
        if browser == "chrome"
        else "SSS_FIREFOX_BINARY"
    )
    override = os.environ.get(environment_name)
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_file() and os.access(candidate, os.X_OK) else None

    candidates = (
        [
            Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            Path.home()
            / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        if browser == "chrome"
        else [
            Path("/Applications/Firefox.app/Contents/MacOS/firefox"),
            Path.home() / "Applications/Firefox.app/Contents/MacOS/firefox",
        ]
    )
    return next(
        (
            candidate
            for candidate in candidates
            if candidate.is_file() and os.access(candidate, os.X_OK)
        ),
        None,
    )


def available_port() -> int:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])
    finally:
        listener.close()


def wait_for_json_endpoint(url: str, process: subprocess.Popen, timeout: float) -> Any:
    deadline = time.monotonic() + timeout
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ValidationError(
                "browser exited before its debugging endpoint was ready"
            )
        try:
            with opener.open(url, timeout=0.5) as response:
                return json.load(response)
        except Exception as error:
            last_error = error
            time.sleep(0.05)
    raise ValidationError(
        "timed out waiting for browser debugging endpoint: {}".format(last_error)
    )


def wait_for_tcp(port: int, process: subprocess.Popen, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ValidationError(
                "browser exited before its debugging endpoint was ready"
            )
        try:
            connection = socket.create_connection(("127.0.0.1", port), timeout=0.25)
            connection.close()
            return
        except OSError:
            time.sleep(0.05)
    raise ValidationError("timed out waiting for browser debugging endpoint")


def terminate_process(process: subprocess.Popen) -> str:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if process.stderr is None:
        return ""
    return process.stderr.read().decode("utf-8", errors="replace")


def validate_result(result: Any) -> Dict[str, Any]:
    if not isinstance(result, dict):
        raise ValidationError("page probe did not return a JSON object")
    expected = {
        "protocol": "file:",
        "enhanced": True,
        "loadedImages": True,
        "externalResources": [],
        "initialVisible": [0],
        "initialStatus": "A (1 of 3)",
        "nextVisible": [1],
        "nextStatus": "B (2 of 3)",
        "keyboardVisible": [2],
        "keyboardStatus": "C (3 of 3)",
        "currentStep": "C. Third",
        "previousDisabled": False,
        "nextDisabled": True,
        "title": "External browser matrix",
    }
    mismatches = {
        key: {"expected": value, "actual": result.get(key)}
        for key, value in expected.items()
        if result.get(key) != value
    }
    csp = result.get("csp")
    if not isinstance(csp, str) or "default-src 'none'" not in csp:
        mismatches["csp"] = {
            "expected": "a deny-by-default policy",
            "actual": csp,
        }
    if mismatches:
        raise ValidationError(
            "page probe failed: {}".format(
                json.dumps(mismatches, ensure_ascii=False, sort_keys=True)
            )
        )
    return result


def validate_in_chrome(
    executable: Path,
    html_url: str,
    profile: Path,
    timeout: float,
) -> Dict[str, Any]:
    port = available_port()
    arguments = [
        str(executable),
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "--disable-domain-reliability",
        "--disable-sync",
        "--metrics-recording-only",
        "--safebrowsing-disable-auto-update",
        "--no-proxy-server",
        "--host-resolver-rules=MAP * ~NOTFOUND",
        "--remote-allow-origins=*",
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port={}".format(port),
        "--user-data-dir={}".format(profile),
        "about:blank",
    ]
    process = subprocess.Popen(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    websocket: Optional[WebSocket] = None
    diagnostic = ""
    try:
        version = wait_for_json_endpoint(
            "http://127.0.0.1:{}/json/version".format(port),
            process,
            timeout,
        )
        websocket_url = version.get("webSocketDebuggerUrl")
        if not isinstance(websocket_url, str):
            raise ValidationError("Chrome did not publish a DevTools WebSocket URL")
        websocket = WebSocket(websocket_url, timeout)
        client = ProtocolClient(websocket)
        target = client.request("Target.createTarget", {"url": "about:blank"})
        target_id = target.get("result", {}).get("targetId")
        if not isinstance(target_id, str):
            raise ValidationError("Chrome did not create a validation tab")
        attachment = client.request(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )
        session_id = attachment.get("result", {}).get("sessionId")
        if not isinstance(session_id, str):
            raise ValidationError("Chrome did not attach to the validation tab")
        client.request("Page.enable", session_id=session_id)
        client.request("Runtime.enable", session_id=session_id)
        client.request(
            "Page.navigate",
            {"url": html_url},
            session_id=session_id,
        )
        deadline = time.monotonic() + timeout
        while True:
            ready = client.request(
                "Runtime.evaluate",
                {
                    "expression": "document.readyState",
                    "returnByValue": True,
                },
                session_id=session_id,
            )
            state = (
                ready.get("result", {})
                .get("result", {})
                .get("value")
            )
            if state == "complete":
                break
            if time.monotonic() >= deadline:
                raise ValidationError("Chrome did not finish loading the local file")
            time.sleep(0.05)
        evaluated = client.request(
            "Runtime.evaluate",
            {
                "expression": PROBE_EXPRESSION,
                "awaitPromise": True,
                "returnByValue": True,
            },
            session_id=session_id,
        )
        result_payload = evaluated.get("result", {})
        remote = result_payload.get("result", {})
        if remote.get("subtype") == "error" or "exceptionDetails" in result_payload:
            raise ValidationError(
                "Chrome page probe threw: {}".format(json.dumps(evaluated))
            )
        encoded = remote.get("value")
        if not isinstance(encoded, str):
            raise ValidationError("Chrome page probe returned no string value")
        return validate_result(json.loads(encoded))
    finally:
        if websocket is not None:
            websocket.close()
        diagnostic = terminate_process(process)
        if process.returncode not in (0, -15) and diagnostic:
            print(diagnostic, file=sys.stderr)


def write_firefox_preferences(profile: Path) -> None:
    profile.mkdir(parents=True, exist_ok=True)
    preferences = {
        "app.update.enabled": False,
        "browser.safebrowsing.downloads.enabled": False,
        "browser.safebrowsing.malware.enabled": False,
        "browser.safebrowsing.phishing.enabled": False,
        "browser.search.suggest.enabled": False,
        "browser.shell.checkDefaultBrowser": False,
        "browser.startup.homepage": "about:blank",
        "browser.tabs.warnOnClose": False,
        "browser.urlbar.quicksuggest.enabled": False,
        "datareporting.healthreport.uploadEnabled": False,
        "datareporting.policy.dataSubmissionEnabled": False,
        "network.captive-portal-service.enabled": False,
        "network.connectivity-service.enabled": False,
        "network.dns.disablePrefetch": True,
        "network.http.speculative-parallel-limit": 0,
        "network.prefetch-next": False,
        "network.proxy.http": "127.0.0.1",
        "network.proxy.http_port": 9,
        "network.proxy.no_proxies_on": "",
        "network.proxy.ssl": "127.0.0.1",
        "network.proxy.ssl_port": 9,
        "network.proxy.type": 1,
        "toolkit.telemetry.enabled": False,
        "toolkit.telemetry.unified": False,
    }
    lines = [
        "user_pref({}, {});".format(json.dumps(name), json.dumps(value))
        for name, value in sorted(preferences.items())
    ]
    (profile / "user.js").write_text("\n".join(lines) + "\n", encoding="utf-8")


def bidi_string_value(response: Dict[str, Any]) -> str:
    result = response.get("result", {})
    evaluation = result.get("result", {}) if isinstance(result, dict) else {}
    value = evaluation.get("value") if isinstance(evaluation, dict) else None
    if not isinstance(value, str):
        raise ValidationError(
            "Firefox page probe returned no string value: {}".format(
                json.dumps(response)
            )
        )
    return value


def validate_in_firefox(
    executable: Path,
    html_url: str,
    profile: Path,
    timeout: float,
) -> Dict[str, Any]:
    write_firefox_preferences(profile)
    port = available_port()
    arguments = [
        str(executable),
        "--headless",
        "--no-remote",
        "--profile",
        str(profile),
        "--remote-debugging-port",
        str(port),
        "about:blank",
    ]
    process = subprocess.Popen(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    websocket: Optional[WebSocket] = None
    diagnostic = ""
    try:
        wait_for_tcp(port, process, timeout)
        connection_errors = []
        for path in ("/session", "/"):
            try:
                websocket = WebSocket(
                    "ws://127.0.0.1:{}{}".format(port, path),
                    timeout,
                )
                break
            except (OSError, ValidationError) as error:
                connection_errors.append("{}: {}".format(path, error))
        if websocket is None:
            raise ValidationError(
                "Firefox did not accept a WebDriver BiDi connection ({})".format(
                    "; ".join(connection_errors)
                )
            )
        client = ProtocolClient(websocket)
        client.request(
            "session.new",
            {
                "capabilities": {
                    "alwaysMatch": {
                        "browserName": "firefox",
                        "acceptInsecureCerts": False,
                    }
                }
            },
        )
        created = client.request("browsingContext.create", {"type": "tab"})
        context = created.get("result", {}).get("context")
        if not isinstance(context, str):
            raise ValidationError("Firefox did not create a validation tab")
        client.request(
            "browsingContext.navigate",
            {
                "context": context,
                "url": html_url,
                "wait": "complete",
            },
        )
        evaluated = client.request(
            "script.evaluate",
            {
                "expression": PROBE_EXPRESSION,
                "target": {"context": context},
                "awaitPromise": True,
                "resultOwnership": "none",
            },
        )
        result = validate_result(json.loads(bidi_string_value(evaluated)))
        client.request("browsingContext.close", {"context": context})
        client.request("session.end")
        return result
    finally:
        if websocket is not None:
            websocket.close()
        diagnostic = terminate_process(process)
        if process.returncode not in (0, -15) and diagnostic:
            print(diagnostic, file=sys.stderr)


def browser_version(executable: Path) -> str:
    try:
        completed = subprocess.run(
            [str(executable), "--version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=5,
            check=False,
        )
        return completed.stdout.decode("utf-8", errors="replace").strip()
    except (OSError, subprocess.TimeoutExpired):
        return executable.name


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a generated composition HTML file in an isolated "
            "headless Chrome or Firefox process."
        )
    )
    parser.add_argument("--browser", choices=("chrome", "firefox"), required=True)
    parser.add_argument("--html", type=Path, required=True)
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if not 1 <= arguments.timeout <= 300:
        print("error: --timeout must be between 1 and 300 seconds", file=sys.stderr)
        return 1
    html = arguments.html.resolve()
    if not html.is_file():
        print("error: HTML fixture does not exist: {}".format(html), file=sys.stderr)
        return 1
    executable = locate_browser(arguments.browser)
    if executable is None:
        override_name = (
            "SSS_GOOGLE_CHROME_BINARY"
            if arguments.browser == "chrome"
            else "SSS_FIREFOX_BINARY"
        )
        if os.environ.get(override_name):
            print(
                "error: {} does not name an executable browser: {}".format(
                    override_name,
                    os.environ[override_name],
                ),
                file=sys.stderr,
            )
            return 1
        print(
            "SKIP: {} is not installed; no browser validation was performed.".format(
                "Google Chrome" if arguments.browser == "chrome" else "Firefox"
            )
        )
        return SKIP_STATUS

    try:
        with tempfile.TemporaryDirectory(
            prefix="SnipSnipSnip-{}-html-".format(arguments.browser)
        ) as temporary:
            profile = Path(temporary) / "profile"
            if arguments.browser == "chrome":
                result = validate_in_chrome(
                    executable,
                    html.as_uri(),
                    profile,
                    arguments.timeout,
                )
            else:
                result = validate_in_firefox(
                    executable,
                    html.as_uri(),
                    profile,
                    arguments.timeout,
                )
        print(
            json.dumps(
                {
                    "browser": arguments.browser,
                    "version": browser_version(executable),
                    "profile": "temporary",
                    "externalNetworkRequests": len(result["externalResources"]),
                    "result": "passed",
                },
                sort_keys=True,
            )
        )
        return 0
    except (OSError, ValueError, ValidationError, json.JSONDecodeError) as error:
        print(
            "error: {} browser validation failed: {}".format(
                arguments.browser,
                error,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
