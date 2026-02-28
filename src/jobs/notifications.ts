/**
 * Telegram notifications for job status updates.
 */

import type { Job, ProgressUpdate } from './store.js';

const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';

export async function sendTelegramNotification(job: Job, progress: ProgressUpdate): Promise<void> {
  if (!TELEGRAM_BOT_TOKEN) {
    console.warn('TELEGRAM_BOT_TOKEN not set, skipping notification');
    return;
  }

  const message = formatNotification(job, progress);

  try {
    const response = await fetch(
      `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          chat_id: job.telegram_chat_id,
          text: message,
          parse_mode: 'Markdown',
        }),
      }
    );

    if (!response.ok) {
      console.error('Failed to send Telegram notification:', await response.text());
    }
  } catch (error) {
    console.error('Error sending Telegram notification:', error);
  }
}

function formatNotification(job: Job, progress: ProgressUpdate): string {
  const icon = getStatusIcon(progress.status);
  const lines: string[] = [];

  lines.push(`${icon} *${progress.status}*`);
  lines.push('');
  lines.push(`\`${job.project_name}\``);

  // Round progress
  if (progress.round_index !== undefined && progress.max_rounds !== undefined) {
    lines.push(`Round ${progress.round_index}/${progress.max_rounds}`);
  }

  // Test results
  if (progress.tests_passed !== undefined || progress.tests_failed !== undefined) {
    const passed = progress.tests_passed ?? 0;
    const failed = progress.tests_failed ?? 0;
    if (failed > 0) {
      lines.push(`Tests: ${passed} passed, ${failed} failed`);
    } else {
      lines.push(`Tests: ${passed} passed`);
    }
  }

  // Blocking issues
  if (progress.blocking_issues && progress.blocking_issues.length > 0) {
    lines.push('');
    lines.push('*Blocking issues:*');
    for (const issue of progress.blocking_issues.slice(0, 3)) {
      lines.push(`• ${issue}`);
    }
    if (progress.blocking_issues.length > 3) {
      lines.push(`_...and ${progress.blocking_issues.length - 3} more_`);
    }
  }

  // Error message
  if (progress.error_message) {
    lines.push('');
    lines.push(`*Error:* ${progress.error_message}`);
  }

  // Proposal summary
  if (progress.proposal_summary) {
    lines.push('');
    lines.push(`*Summary:* ${progress.proposal_summary.slice(0, 200)}${progress.proposal_summary.length > 200 ? '...' : ''}`);
  }

  return lines.join('\n');
}

function getStatusIcon(status: string): string {
  switch (status) {
    case 'SUCCEEDED': return '✅';
    case 'FAILED': return '❌';
    case 'WAITING_APPROVAL': return '⏳';
    case 'RUNNING': return '🔄';
    default: return '📋';
  }
}
