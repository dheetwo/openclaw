/**
 * Job Bot + OpenClaw Proxy (ES Module version)
 *
 * Handles job submission API and proxies other requests to OpenClaw gateway.
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Config
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || process.env.TELEGRAM_OPENCLAW_TOKEN || process.env.TELEGRAM_DEEPCLAW_TOKEN;
const GCP_TOKEN = process.env.OPENCLAW_GCP_BEARER_TOKEN || '';
const JOBS_FILE = process.env.JOBS_FILE || '/data/jobs.json';
const PORT = process.env.PORT || 10000;
const OPENCLAW_PORT = 10001;

console.log('=== Job Proxy Configuration ===');
console.log('BOT_TOKEN:', BOT_TOKEN ? 'SET' : 'NOT SET');
console.log('GCP_TOKEN:', GCP_TOKEN ? 'SET' : 'NOT SET');
console.log('External PORT:', PORT);
console.log('OpenClaw PORT:', OPENCLAW_PORT);
console.log('================================');

// Ensure data dir exists
const dataDir = path.dirname(JOBS_FILE);
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

// Job storage
const loadJobs = () => {
  try { return fs.existsSync(JOBS_FILE) ? JSON.parse(fs.readFileSync(JOBS_FILE, 'utf-8')) : []; }
  catch { return []; }
};
const saveJobs = (jobs) => fs.writeFileSync(JOBS_FILE, JSON.stringify(jobs, null, 2));

// Telegram API helper
const telegram = async (method, body) => {
  if (!BOT_TOKEN) return { ok: false, description: 'BOT_TOKEN not set' };
  try {
    const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/${method}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    return res.json();
  } catch (err) {
    console.error('Telegram API error:', err.message);
    return { ok: false, description: err.message };
  }
};

// Handle Telegram job commands
const handleJobUpdate = async (update) => {
  const msg = update.message;
  if (!msg?.text) return false;

  const chatId = msg.chat.id;
  const userId = msg.from.id;
  const text = msg.text.trim();

  // /newjob <project> <goal>
  if (text.startsWith('/newjob')) {
    console.log('Handling /newjob command');
    const match = text.match(/^\/newjob\s+(\S+)\s+(.+)$/s);
    if (!match) {
      await telegram('sendMessage', {
        chat_id: chatId,
        text: '❌ Usage: /newjob <project-name> <goal>\n\nExample:\n/newjob my-app Fix the login bug',
      });
      return true;
    }

    const [, projectName, goal] = match;
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(projectName)) {
      await telegram('sendMessage', {
        chat_id: chatId,
        text: '❌ Invalid project name. Use only letters, numbers, dots, dashes, underscores.',
      });
      return true;
    }

    const jobs = loadJobs();
    const job = {
      openclaw_job_id: `oc-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      project_name: projectName,
      spec_text: `+++\nproject_name = "${projectName}"\njob_version = 1\nmax_rounds = 3\nworkspace_mode = "in_place"\n+++\n\n${goal}`,
      status: 'pending',
      telegram_user_id: userId,
      telegram_chat_id: chatId,
      created_at: new Date().toISOString(),
    };
    jobs.push(job);
    saveJobs(jobs);

    await telegram('sendMessage', {
      chat_id: chatId,
      text: `✅ Job submitted!\n\nID: \`${job.openclaw_job_id}\`\nProject: ${projectName}\n\nYou'll be notified when it completes.`,
      parse_mode: 'Markdown',
    });
    return true;
  }

  // /jobs - list recent jobs
  if (text === '/jobs') {
    console.log('Handling /jobs command');
    const jobs = loadJobs().filter(j => j.telegram_user_id === userId).slice(-5);
    if (jobs.length === 0) {
      await telegram('sendMessage', { chat_id: chatId, text: 'No jobs found.' });
      return true;
    }
    const list = jobs.map(j => {
      const icon = { pending: '⏳', claimed: '🔄', running: '🔄', succeeded: '✅', failed: '❌' }[j.status] || '❓';
      return `${icon} \`${j.project_name}\` - ${j.status}`;
    }).join('\n');
    await telegram('sendMessage', { chat_id: chatId, text: `Recent jobs:\n\n${list}`, parse_mode: 'Markdown' });
    return true;
  }

  return false; // Not a job command
};

// Proxy request to OpenClaw
const proxyToOpenClaw = (req, res) => {
  const options = {
    hostname: '127.0.0.1',
    port: OPENCLAW_PORT,
    path: req.url,
    method: req.method,
    headers: req.headers,
  };

  const proxyReq = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    console.error('Proxy error:', err.message);
    res.writeHead(502);
    res.end('Bad Gateway');
  });

  req.pipe(proxyReq);
};

// HTTP server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const reqPath = url.pathname;

  // Health check
  if (reqPath === '/health') {
    res.writeHead(200);
    res.end('ok');
    return;
  }

  // Job API config check
  if (reqPath === '/api/jobs/config') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      telegram_bot_token: BOT_TOKEN ? 'SET' : 'NOT SET',
      gcp_bearer_token: GCP_TOKEN ? 'SET' : 'NOT SET',
    }));
    return;
  }

  // Telegram webhook for job commands
  if (reqPath.startsWith('/webhook/') && req.method === 'POST') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const update = JSON.parse(body);
        const handled = await handleJobUpdate(update);
        if (!handled) {
          console.log('Non-job update, ignoring');
        }
      } catch (e) {
        console.error('Webhook error:', e);
      }
      res.writeHead(200);
      res.end('ok');
    });
    return;
  }

  // Job API - auth check
  const authOk = req.headers.authorization === `Bearer ${GCP_TOKEN}`;
  const sendJson = (status, data) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
  };

  if (reqPath.startsWith('/api/jobs') && !authOk) {
    sendJson(401, { error: 'Unauthorized' });
    return;
  }

  // GET /api/jobs/pending
  if (reqPath === '/api/jobs/pending' && req.method === 'GET') {
    const jobs = loadJobs().filter(j => j.status === 'pending');
    sendJson(200, jobs.map(j => ({
      openclaw_job_id: j.openclaw_job_id,
      project_name: j.project_name,
      spec_text: j.spec_text,
      created_at: j.created_at,
    })));
    return;
  }

  // PATCH /api/jobs/:id/claimed
  const claimMatch = reqPath.match(/^\/api\/jobs\/([^/]+)\/claimed$/);
  if (claimMatch && req.method === 'PATCH') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      const { gcp_job_id } = JSON.parse(body || '{}');
      const jobs = loadJobs();
      const job = jobs.find(j => j.openclaw_job_id === claimMatch[1]);
      if (!job || job.status !== 'pending') {
        sendJson(409, { error: 'Not found or already claimed' });
        return;
      }
      job.status = 'claimed';
      job.gcp_job_id = gcp_job_id;
      saveJobs(jobs);
      sendJson(200, { status: 'claimed' });
    });
    return;
  }

  // PATCH /api/jobs/:id/progress
  const progressMatch = reqPath.match(/^\/api\/jobs\/([^/]+)\/progress$/);
  if (progressMatch && req.method === 'PATCH') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      const progress = JSON.parse(body || '{}');
      const jobs = loadJobs();
      const job = jobs.find(j => j.openclaw_job_id === progressMatch[1]);
      if (!job) {
        sendJson(404, { error: 'Not found' });
        return;
      }
      job.last_progress = progress;
      if (progress.status === 'SUCCEEDED') job.status = 'succeeded';
      if (progress.status === 'FAILED') job.status = 'failed';
      if (progress.status === 'RUNNING') job.status = 'running';
      saveJobs(jobs);

      // Send Telegram notification
      if (['SUCCEEDED', 'FAILED', 'WAITING_APPROVAL'].includes(progress.status)) {
        const icon = { SUCCEEDED: '✅', FAILED: '❌', WAITING_APPROVAL: '⏳' }[progress.status];
        let msg = `${icon} *${progress.status}*\n\n\`${job.project_name}\``;
        if (progress.round_index) msg += `\nRound ${progress.round_index}/${progress.max_rounds || '?'}`;
        if (progress.error_message) msg += `\n\n*Error:* ${progress.error_message}`;
        await telegram('sendMessage', { chat_id: job.telegram_chat_id, text: msg, parse_mode: 'Markdown' });
      }
      sendJson(200, { status: 'updated' });
    });
    return;
  }

  // Proxy everything else to OpenClaw
  proxyToOpenClaw(req, res);
});

// Start OpenClaw gateway on internal port
const startOpenClaw = () => {
  console.log('Starting OpenClaw gateway on port', OPENCLAW_PORT);
  const openclaw = spawn('node', ['openclaw.mjs', 'gateway', '--allow-unconfigured', '--bind', 'lan', '--port', String(OPENCLAW_PORT)], {
    cwd: '/app',
    env: {
      ...process.env,
      PORT: String(OPENCLAW_PORT),
      // Allow Control UI in non-loopback mode
      OPENCLAW_GATEWAY_CONTROL_UI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK: 'true',
    },
    stdio: 'inherit',
  });

  openclaw.on('error', (err) => {
    console.error('Failed to start OpenClaw:', err);
  });

  openclaw.on('exit', (code) => {
    console.error('OpenClaw exited with code:', code);
    setTimeout(startOpenClaw, 5000);
  });
};

// Start
server.listen(PORT, async () => {
  console.log(`Job proxy running on port ${PORT}`);

  // Start OpenClaw
  startOpenClaw();

  // Set Telegram webhook
  const publicUrl = process.env.RENDER_EXTERNAL_URL;
  if (publicUrl && BOT_TOKEN) {
    const webhookUrl = `${publicUrl}/webhook/${BOT_TOKEN}`;
    console.log('Setting webhook...');
    const result = await telegram('setWebhook', { url: webhookUrl });
    console.log('Webhook set:', result.ok ? 'success' : result.description);
  }
});
