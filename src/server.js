import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const publicDir = path.resolve(__dirname, "../public");
const port = Number(process.env.PORT ?? 3000);

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon"
};

const clients = new Map();
let hostId = null;

function json(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": payload.length,
    "cache-control": "no-store"
  });
  res.end(payload);
}

function serveFile(req, res) {
  if (req.url === "/health") {
    json(res, 200, { ok: true });
    return;
  }

  const requestPath = decodeURIComponent((req.url ?? "/").split("?")[0]);
  const relativePath = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
  const filePath = path.resolve(publicDir, relativePath);

  if (!filePath.startsWith(publicDir + path.sep)) {
    json(res, 403, { error: "Forbidden" });
    return;
  }

  fs.stat(filePath, (error, stat) => {
    if (error || !stat.isFile()) {
      json(res, 404, { error: "Not found" });
      return;
    }

    const contentType = mimeTypes[path.extname(filePath)] ?? "application/octet-stream";
    res.writeHead(200, {
      "content-type": contentType,
      "content-length": stat.size,
      "cache-control": "no-cache"
    });
    fs.createReadStream(filePath).pipe(res);
  });
}

const server = http.createServer(serveFile);

function makeAcceptKey(key) {
  return crypto
    .createHash("sha1")
    .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
}

function encodeFrame(text) {
  const payload = Buffer.from(text);
  const length = payload.length;
  let header;

  if (length < 126) {
    header = Buffer.from([0x81, length]);
  } else if (length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }

  return Buffer.concat([header, payload]);
}

function decodeFrames(state, chunk) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  const messages = [];

  while (state.buffer.length >= 2) {
    const first = state.buffer[0];
    const second = state.buffer[1];
    const opcode = first & 0x0f;
    const masked = Boolean(second & 0x80);
    let length = second & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (state.buffer.length < 4) break;
      length = state.buffer.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (state.buffer.length < 10) break;
      const bigLength = state.buffer.readBigUInt64BE(2);
      if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Frame too large");
      length = Number(bigLength);
      offset = 10;
    }

    const maskLength = masked ? 4 : 0;
    const frameLength = offset + maskLength + length;
    if (state.buffer.length < frameLength) break;

    if (opcode === 0x8) {
      state.closed = true;
      state.buffer = state.buffer.subarray(frameLength);
      break;
    }

    if (opcode === 0x9) {
      const pingPayload = state.buffer.subarray(offset + maskLength, frameLength);
      state.socket.write(Buffer.concat([Buffer.from([0x8a, pingPayload.length]), pingPayload]));
      state.buffer = state.buffer.subarray(frameLength);
      continue;
    }

    if (opcode !== 0x1) {
      state.buffer = state.buffer.subarray(frameLength);
      continue;
    }

    let payload = Buffer.from(state.buffer.subarray(offset + maskLength, frameLength));
    if (masked) {
      const mask = state.buffer.subarray(offset, offset + 4);
      for (let index = 0; index < payload.length; index += 1) {
        payload[index] ^= mask[index % 4];
      }
    }

    messages.push(payload.toString("utf8"));
    state.buffer = state.buffer.subarray(frameLength);
  }

  return messages;
}

function send(client, message) {
  if (!client.socket.destroyed) {
    client.socket.write(encodeFrame(JSON.stringify(message)));
  }
}

function broadcast(message, exceptId) {
  for (const [id, client] of clients) {
    if (id !== exceptId) send(client, message);
  }
}

function closeClient(id) {
  const client = clients.get(id);
  if (!client) return;

  clients.delete(id);
  if (hostId === id) {
    hostId = null;
    broadcast({ type: "host-offline" });
  } else if (hostId) {
    const host = clients.get(hostId);
    if (host) send(host, { type: "viewer-left", viewerId: id });
  }
}

function handleMessage(id, raw) {
  const client = clients.get(id);
  if (!client) return;

  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    send(client, { type: "error", message: "Invalid JSON" });
    return;
  }

  if (message.type === "register") {
    if (message.role !== "host" && message.role !== "viewer") return;
    client.role = message.role;

    if (message.role === "host") {
      if (hostId && hostId !== id) {
        send(client, { type: "error", message: "A host is already active" });
        return;
      }
      hostId = id;
      broadcast({ type: "host-online", hostId: id }, id);
    } else if (hostId) {
      const host = clients.get(hostId);
      if (host) send(host, { type: "viewer-joined", viewerId: id });
    }
    return;
  }

  if (message.type === "signal" && typeof message.target === "string") {
    const target = clients.get(message.target);
    if (target) {
      send(target, { type: "signal", from: id, payload: message.payload });
    }
  }
}

server.on("upgrade", (req, socket) => {
  if (req.url !== "/signal") {
    socket.destroy();
    return;
  }

  const key = req.headers["sec-websocket-key"];
  if (typeof key !== "string") {
    socket.destroy();
    return;
  }

  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${makeAcceptKey(key)}`,
    "\r\n"
  ].join("\r\n"));

  const id = crypto.randomUUID();
  const client = { id, role: null, socket, buffer: Buffer.alloc(0), closed: false };
  clients.set(id, client);
  send(client, { type: "welcome", id, hostOnline: Boolean(hostId) });

  socket.on("data", (chunk) => {
    try {
      for (const message of decodeFrames(client, chunk)) handleMessage(id, message);
      if (client.closed) socket.end();
    } catch {
      socket.destroy();
    }
  });

  socket.on("close", () => closeClient(id));
  socket.on("error", () => closeClient(id));
});

function getLanAddresses() {
  const result = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) result.push(entry.address);
    }
  }
  return result;
}

server.listen(port, "0.0.0.0", () => {
  console.log(`Host:   http://localhost:${port}`);
  for (const address of getLanAddresses()) {
    console.log(`Viewer: http://${address}:${port}`);
  }
});
