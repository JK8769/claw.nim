const { Client } = require('@larksuiteoapi/node-sdk');
const WebSocket = require('ws');

// Feishu Gateway Bridge for NimClaw
// This script handles the stable ws/v2 connection and binary heartbeats.

const appId = process.env.FEISHU_APP_ID || process.env.LARK_APP_ID;
const appSecret = process.env.FEISHU_APP_SECRET || process.env.LARK_APP_SECRET;

const fs = require('fs');
const path = require('path');
const debugLogPath = path.join(process.env.NIMCLAW_DIR || '.', 'debug_feishu.log');

function debugLog(msg) {
    const timestamp = new Date().toISOString();
    fs.appendFileSync(debugLogPath, `[${timestamp}] ${msg}\n`);
}

function sendLog(obj) {
    const line = JSON.stringify(obj) + '\n';
    process.stdout.write(line);
    debugLog(`OUT: ${line.trim()}`);
}

if (!appId || !appSecret) {
    sendLog({ type: 'error', msg: 'Missing FEISHU_APP_ID/LARK_APP_ID or FEISHU_APP_SECRET/LARK_APP_SECRET' });
    process.exit(1);
}

// Minimal implementation using the same protocol logic as the Nim version
// but leveraging the stability of Node's 'ws' library over SSL.

async function start() {
    try {
        const client = new Client({ appId, appSecret });
        
        // 1. Handshake to get wsUrl
        const response = await client.request({
            method: 'POST',
            url: 'https://open.feishu.cn/callback/ws/endpoint',
            data: { AppID: appId, AppSecret: appSecret }
        });

        if (response.code !== 0) {
            throw new Error(`Handshake failed: ${response.msg}`);
        }

        const { URL: wsUrl } = response.data;
        const ws = new WebSocket(wsUrl);

        ws.on('open', () => {
            sendLog({ type: 'connected', url: wsUrl });
        });

        ws.on('message', (data, isBinary) => {
            const now = new Date().toISOString();
            const msg = `IN: [${now}] Received ${isBinary ? 'binary' : 'text'} frame, size: ${data.length}`;
            debugLog(msg);
            process.stderr.write(`${msg}\n`);
            if (isBinary) {
                // Forward binary frames as Hex to Nim for decoding
                sendLog({ type: 'event', data: data.toString('hex') });
            } else {
                sendLog({ type: 'log', msg: `Text frame received: ${data.toString()}` });
            }
        });

        ws.on('close', () => {
            sendLog({ type: 'error', msg: 'WebSocket closed' });
            process.exit(1);
        });

        ws.on('error', (err) => {
            sendLog({ type: 'error', msg: err.message });
        });

        // 2. Nim-to-Bridge communication (for ACKs and other commands)
        const readline = require('readline');

        // Handle commands from Nim via stdin (for ACKs or outbound frames)
        const rl = readline.createInterface({
          input: process.stdin,
          terminal: false
        });

        rl.on('line', (line) => {
          if (!line.trim()) return;
          try {
            const cmd = JSON.parse(line);
            if (cmd.type === 'send') {
              const buf = Buffer.from(cmd.data, 'hex');
              if (ws && ws.readyState === 1) { // 1 = OPEN
                ws.send(buf);
              }
            }
          } catch (e) {
            console.error('[FEISHU] Stdin parse error:', e.message);
          }
        });

        rl.on('close', () => {
          sendLog({ type: 'log', msg: 'Stdin closed, exiting bridge' });
          process.exit(0);
        });

        // 3. Heartbeat loop (Ping every 30s)
        const urlParams = new URLSearchParams(wsUrl.split('?')[1]);
        const serviceId = parseInt(urlParams.get('service_id') || '0');
        
        setInterval(() => {
            if (ws.readyState === WebSocket.OPEN) {
                // Construct a minimal Protobuf Ping frame (methodID 0 = Control)
                // [seqID=0, logID=0, service=serviceId, methodID=0, headers=[], payload=[]]
                // For simplicity, a 0-byte binary frame is often accepted as a keep-alive
                // but let's send a specifically marked binary frame if possible.
                // Research indicates a 0-byte binary frame is a standard WebSocket ping.
                ws.ping(); 
                // sendLog({ type: 'log', msg: 'Sent WS ping' }); // Throttled
            }
        }, 30000); // 30s production heartbeat

    } catch (err) {
        sendLog({ type: 'error', msg: err.message });
        process.exit(1);
    }
}

start();
