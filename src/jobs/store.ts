/**
 * Job storage module for OpenClaw.
 * Stores jobs in JSON file with pending/claimed/completed states.
 */

import { loadJsonFile, saveJsonFile } from '../infra/json-file.js';

export interface Job {
  openclaw_job_id: string;
  project_name: string;
  spec_text: string;
  status: 'pending' | 'claimed' | 'running' | 'succeeded' | 'failed';
  gcp_job_id?: string;
  telegram_user_id: number;
  telegram_chat_id: number;
  last_progress?: ProgressUpdate;
  created_at: string;
  updated_at: string;
}

export interface ProgressUpdate {
  status: string;
  event_ts?: string;
  event_hash?: string;
  round_index?: number;
  max_rounds?: number;
  tests_passed?: number;
  tests_failed?: number;
  proposal_summary?: string;
  blocking_issues?: string[];
  error_category?: string;
  error_message?: string;
}

const JOBS_FILE = 'data/jobs.json';

function loadJobs(): Job[] {
  try {
    const data = loadJsonFile(JOBS_FILE);
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

function saveJobs(jobs: Job[]): void {
  saveJsonFile(JOBS_FILE, jobs);
}

export function createJob(params: {
  project_name: string;
  spec_text: string;
  telegram_user_id: number;
  telegram_chat_id: number;
}): Job {
  const jobs = loadJobs();
  const now = new Date().toISOString();

  const job: Job = {
    openclaw_job_id: `oc-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    project_name: params.project_name,
    spec_text: params.spec_text,
    status: 'pending',
    telegram_user_id: params.telegram_user_id,
    telegram_chat_id: params.telegram_chat_id,
    created_at: now,
    updated_at: now,
  };

  jobs.push(job);
  saveJobs(jobs);
  return job;
}

export function getPendingJobs(limit: number = 50): Job[] {
  const jobs = loadJobs();
  return jobs
    .filter(j => j.status === 'pending')
    .slice(0, limit);
}

export function claimJob(openclaw_job_id: string, gcp_job_id: string): Job | null {
  const jobs = loadJobs();
  const job = jobs.find(j => j.openclaw_job_id === openclaw_job_id);

  if (!job) return null;
  if (job.status !== 'pending') return null;

  job.status = 'claimed';
  job.gcp_job_id = gcp_job_id;
  job.updated_at = new Date().toISOString();

  saveJobs(jobs);
  return job;
}

export function updateJobProgress(openclaw_job_id: string, progress: ProgressUpdate): Job | null {
  const jobs = loadJobs();
  const job = jobs.find(j => j.openclaw_job_id === openclaw_job_id);

  if (!job) return null;

  job.last_progress = progress;
  job.updated_at = new Date().toISOString();

  // Update status based on progress
  if (progress.status === 'SUCCEEDED') {
    job.status = 'succeeded';
  } else if (progress.status === 'FAILED') {
    job.status = 'failed';
  } else if (progress.status === 'RUNNING') {
    job.status = 'running';
  }

  saveJobs(jobs);
  return job;
}

export function getJobById(openclaw_job_id: string): Job | null {
  const jobs = loadJobs();
  return jobs.find(j => j.openclaw_job_id === openclaw_job_id) || null;
}

export function getJobsByUser(telegram_user_id: number): Job[] {
  const jobs = loadJobs();
  return jobs.filter(j => j.telegram_user_id === telegram_user_id);
}
