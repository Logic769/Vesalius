#!/usr/bin/env python3
"""A minimal MCP client over stdio (newline-delimited JSON-RPC 2.0) that drives the real `vesalius mcp` server,
the same way Claude Code does: initialize, tools/list, tools/call.

Usage:
  mcp_client.py --repo <path> [--vesalius <binary>] list
  mcp_client.py --repo <path> [--vesalius <binary>] call <tool> '<json arguments>'
"""
import argparse, json, os, select, subprocess, sys, time

DEFAULT_BINARY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "VesaliusKit", ".build", "release", "vesalius")


class MCPError(RuntimeError):
    pass


class MCPClient:
    def __init__(self, repo, binary=DEFAULT_BINARY, env=None, extra_args=(), log_path=os.devnull):
        self.log = open(log_path, "w")
        self.proc = subprocess.Popen([binary, "mcp", "--repo", repo, *extra_args], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.log, env={**os.environ, **(env or {})})
        self.next_id = 1
        self.buffer = b""

    def request(self, method, params=None, timeout=600):
        """Sends one request and returns (result, milliseconds). Raises MCPError on a JSON-RPC error."""
        rid = self.next_id
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        started = time.monotonic()
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()
        while True:
            response = self._read_message(started + timeout)
            if response.get("id") != rid:
                continue  # a notification or a stale response
            ms = (time.monotonic() - started) * 1000
            if "error" in response:
                raise MCPError(f"{method}: {response['error']}")
            return response["result"], ms

    def notify(self, method, params=None):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}}) + "\n").encode())
        self.proc.stdin.flush()

    def initialize(self):
        result, ms = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                 "clientInfo": {"name": "vesalius-golden", "version": "1"}})
        self.notify("notifications/initialized")
        return result, ms

    def list_tools(self):
        result, ms = self.request("tools/list")
        return result["tools"], ms

    def call(self, name, arguments, timeout=600):
        """Returns (text, milliseconds, is_error) for one tools/call."""
        result, ms = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return text, ms, bool(result.get("isError"))

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self.log.close()

    def _read_message(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise MCPError("timed out waiting for the server")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
            if not chunk:
                raise MCPError(f"server exited (code {self.proc.poll()})")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line) if line.strip() else self._read_message(deadline)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--vesalius", default=DEFAULT_BINARY)
    parser.add_argument("command", choices=["list", "call"])
    parser.add_argument("tool", nargs="?")
    parser.add_argument("arguments", nargs="?", default="{}")
    args = parser.parse_args()
    client = MCPClient(os.path.expanduser(args.repo), args.vesalius)
    try:
        info, ms = client.initialize()
        print(f"# initialize {ms:.0f} ms: {info.get('serverInfo')}", file=sys.stderr)
        if args.command == "list":
            tools, ms = client.list_tools()
            print(f"# tools/list {ms:.0f} ms, {len(tools)} tools, {len(json.dumps(tools))} bytes", file=sys.stderr)
            print(json.dumps(tools, indent=1))
        else:
            text, ms, is_error = client.call(args.tool, json.loads(args.arguments))
            print(f"# {args.tool} {ms:.0f} ms, {len(text)} chars{' (error)' if is_error else ''}", file=sys.stderr)
            print(text)
    finally:
        client.close()


if __name__ == "__main__":
    main()
