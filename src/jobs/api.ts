/**
 * API endpoints for GCP to poll jobs.
 *
 * Endpoints:
 * - GET /api/jobs/pending - Fetch unclaimed jobs
 * - PATCH /api/jobs/:id/claimed - Claim a job
 * - PATCH /api/jobs/:id/progress - Update job progress
 */

import { Hono } from 'hono';
import { bearerAuth } from 'hono/bearer-auth';
import {
  getPendingJobs,
  claimJob,
  updateJobProgress,
  getJobById,
  type ProgressUpdate
} from './store.js';
import { sendTelegramNotification } from './notifications.js';

const BEARER_TOKEN = process.env.OPENCLAW_GCP_BEARER_TOKEN || '';

export const jobsApi = new Hono();

// Protect all routes with bearer auth
jobsApi.use('/*', bearerAuth({ token: BEARER_TOKEN }));

// GET /api/jobs/pending - Fetch unclaimed jobs
jobsApi.get('/pending', (c) => {
  const limit = parseInt(c.req.query('limit') || '50', 10);
  const jobs = getPendingJobs(limit);

  return c.json(jobs.map(j => ({
    openclaw_job_id: j.openclaw_job_id,
    project_name: j.project_name,
    spec_text: j.spec_text,
    created_at: j.created_at,
  })));
});

// PATCH /api/jobs/:id/claimed - Claim a job
jobsApi.patch('/:id/claimed', async (c) => {
  const openclaw_job_id = c.req.param('id');
  const body = await c.req.json<{ gcp_job_id: string }>();

  const job = claimJob(openclaw_job_id, body.gcp_job_id);

  if (!job) {
    return c.json({ error: 'Job not found or already claimed' }, 409);
  }

  return c.json({ status: 'claimed', gcp_job_id: body.gcp_job_id });
});

// PATCH /api/jobs/:id/progress - Update job progress
jobsApi.patch('/:id/progress', async (c) => {
  const openclaw_job_id = c.req.param('id');
  const progress = await c.req.json<ProgressUpdate>();

  const job = updateJobProgress(openclaw_job_id, progress);

  if (!job) {
    return c.json({ error: 'Job not found' }, 404);
  }

  // Send Telegram notification for significant status changes
  if (['SUCCEEDED', 'FAILED', 'WAITING_APPROVAL'].includes(progress.status)) {
    await sendTelegramNotification(job, progress);
  }

  return c.json({ status: 'updated' });
});

// GET /api/jobs/:id - Get job details (for debugging)
jobsApi.get('/:id', (c) => {
  const openclaw_job_id = c.req.param('id');
  const job = getJobById(openclaw_job_id);

  if (!job) {
    return c.json({ error: 'Job not found' }, 404);
  }

  return c.json(job);
});
