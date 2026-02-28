/**
 * /newjob conversation handler for Telegram.
 * Guides user through job submission form.
 */

import type { Context, Conversation } from '../telegram/conversation-types.js';
import { createJob } from './store.js';

// Validate project name: alphanumeric, dots, dashes, underscores
const PROJECT_NAME_REGEX = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

interface NewJobForm {
  project_name: string;
  goal: string;
  max_rounds: number;
  workspace_mode: 'in_place' | 'bootstrap';
}

export async function newJobConversation(
  conversation: Conversation,
  ctx: Context
): Promise<void> {
  const form: Partial<NewJobForm> = {};

  // Step 1: Project name
  await ctx.reply(
    '📝 *New Job Submission*\n\n' +
    'Step 1/4: Enter the *project name*\n' +
    '_(alphanumeric, dots, dashes, underscores only)_',
    { parse_mode: 'Markdown' }
  );

  while (!form.project_name) {
    const response = await conversation.waitFor('message:text');
    const name = response.message.text.trim();

    if (!PROJECT_NAME_REGEX.test(name)) {
      await ctx.reply(
        '❌ Invalid project name. Use only letters, numbers, dots, dashes, and underscores.\n' +
        'Example: `my-project-v2`',
        { parse_mode: 'Markdown' }
      );
      continue;
    }

    form.project_name = name;
  }

  // Step 2: Goal description
  await ctx.reply(
    'Step 2/4: Describe the *goal* for this job.\n' +
    '_(What should the agents accomplish? Be specific.)_',
    { parse_mode: 'Markdown' }
  );

  const goalResponse = await conversation.waitFor('message:text');
  form.goal = goalResponse.message.text.trim();

  // Step 3: Max rounds
  await ctx.reply(
    'Step 3/4: How many *rounds* maximum?\n' +
    '_(1-20, default: 3)_',
    { parse_mode: 'Markdown' }
  );

  const roundsResponse = await conversation.waitFor('message:text');
  const rounds = parseInt(roundsResponse.message.text.trim(), 10);
  form.max_rounds = (rounds >= 1 && rounds <= 20) ? rounds : 3;

  // Step 4: Workspace mode
  await ctx.reply(
    'Step 4/4: Select *workspace mode*:\n\n' +
    '`in_place` - Work in existing project directory\n' +
    '`bootstrap` - Create new workspace from scratch\n\n' +
    '_(Reply with `in_place` or `bootstrap`, default: in_place)_',
    { parse_mode: 'Markdown' }
  );

  const modeResponse = await conversation.waitFor('message:text');
  const mode = modeResponse.message.text.trim().toLowerCase();
  form.workspace_mode = mode === 'bootstrap' ? 'bootstrap' : 'in_place';

  // Generate job spec
  const specText = generateJobSpec(form as NewJobForm);

  // Confirm
  await ctx.reply(
    '📋 *Job Summary*\n\n' +
    `Project: \`${form.project_name}\`\n` +
    `Max rounds: ${form.max_rounds}\n` +
    `Mode: ${form.workspace_mode}\n\n` +
    `Goal:\n${form.goal}\n\n` +
    '_Reply "yes" to submit or "cancel" to abort._',
    { parse_mode: 'Markdown' }
  );

  const confirmResponse = await conversation.waitFor('message:text');
  const confirm = confirmResponse.message.text.trim().toLowerCase();

  if (confirm !== 'yes' && confirm !== 'y') {
    await ctx.reply('❌ Job submission cancelled.');
    return;
  }

  // Create job
  const job = createJob({
    project_name: form.project_name!,
    spec_text: specText,
    telegram_user_id: ctx.from!.id,
    telegram_chat_id: ctx.chat!.id,
  });

  await ctx.reply(
    '✅ *Job Submitted!*\n\n' +
    `ID: \`${job.openclaw_job_id}\`\n` +
    `Status: ${job.status}\n\n` +
    '_You will receive notifications when the job progresses._',
    { parse_mode: 'Markdown' }
  );
}

function generateJobSpec(form: NewJobForm): string {
  return `+++
project_name = "${form.project_name}"
job_version = 1
max_rounds = ${form.max_rounds}
workspace_mode = "${form.workspace_mode}"
+++

${form.goal}
`;
}
