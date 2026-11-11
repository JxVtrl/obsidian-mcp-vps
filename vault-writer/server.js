// Tiny authenticated HTTP read/write endpoint for the vault.
// For automation tools (n8n, scripts, webhooks) that speak HTTP, not MCP.
//
//   GET  /vault/<path>   read a note
//   HEAD /vault/<path>   check it exists
//   PUT  /vault/<path>   create or overwrite (parent folders are created)
//
// No dependencies. Node 18+.
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const VAULT_ROOT = path.resolve(process.env.VAULT_DIR || '/opt/vault');
const TOKEN = process.env.WRITE_TOKEN;
const PORT = process.env.PORT || 8082;
const HOST = process.env.HOST || '127.0.0.1';

if (!TOKEN || TOKEN.length < 32) {
  console.error('WRITE_TOKEN is missing or shorter than 32 chars. Refusing to start.');
  process.exit(1);
}

const EXPECTED = Buffer.from(`Bearer ${TOKEN}`);

function authorized(header) {
  const got = Buffer.from(header || '');
  return got.length === EXPECTED.length && crypto.timingSafeEqual(got, EXPECTED);
}

// Maps a request URL to a file inside the vault, or null if it escapes it.
// Parsing with URL() drops the query string, so it never leaks into a filename.
function resolveVaultPath(reqUrl) {
  let rel;
  try {
    const u = new URL(reqUrl, 'http://localhost');
    if (!u.pathname.startsWith('/vault/')) return null;
    rel = decodeURIComponent(u.pathname.slice('/vault/'.length));
  } catch {
    return null;
  }
  const full = path.resolve(VAULT_ROOT, rel);
  if (!full.startsWith(VAULT_ROOT + path.sep)) return null;
  if (full.split(path.sep).includes('.git')) return null;
  return full;
}

const json = (res, code, obj) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
};

const server = http.createServer((req, res) => {
  if (!authorized(req.headers['authorization'])) {
    return json(res, 401, { error: 'Unauthorized' });
  }

  const filePath = resolveVaultPath(req.url);
  if (!filePath) return json(res, 400, { error: 'Invalid path' });

  if (req.method === 'GET' || req.method === 'HEAD') {
    fs.readFile(filePath, (err, data) => {
      if (err) {
        return json(res, err.code === 'ENOENT' ? 404 : 500, { error: err.code });
      }
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': data.length,
      });
      res.end(req.method === 'HEAD' ? undefined : data);
    });
    return;
  }

  if (req.method === 'PUT') {
    const body = [];
    req.on('data', (c) => body.push(c));
    req.on('end', () => {
      fs.mkdir(path.dirname(filePath), { recursive: true }, (err) => {
        if (err) return json(res, 500, { error: err.code });
        fs.writeFile(filePath, Buffer.concat(body), (err) => {
          if (err) return json(res, 500, { error: err.code });
          res.writeHead(204);
          res.end();
        });
      });
    });
    return;
  }

  res.writeHead(405, { Allow: 'GET, HEAD, PUT', 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Method not allowed', allow: 'GET, HEAD, PUT' }));
});

server.listen(PORT, HOST, () => console.log(`vault-writer on ${HOST}:${PORT}`));
