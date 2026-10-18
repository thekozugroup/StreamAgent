/**
 * @process streamagent/context-polish
 * @description Desktop UI implementation and TDD convergence: corner identity, contextual keys, native acceptance.
 * @skill swift-swiftui specializations/mobile-development/skills/swift-swiftui/SKILL.md
 * @agent desktop-ux-analyst specializations/desktop-development/agents/desktop-ux-analyst/AGENT.md
 */
import { defineTask } from '@a5c-ai/babysitter-sdk';
const work = defineTask('context-polish-work', (args, taskCtx) => ({
  kind: 'agent', title: args.title,
  agent: { name: 'general-purpose', prompt: { role: args.role || 'Native macOS engineer', task: args.title, context: args, instructions: ['Perform actual work and return changed paths and evidence. Do not orchestrate babysitter.'], outputFormat: 'JSON' } },
  io: { inputJsonPath: `tasks/${taskCtx.effectId}/input.json`, outputJsonPath: `tasks/${taskCtx.effectId}/output.json` }
}));
const check = defineTask('context-polish-check', (args, taskCtx) => ({
  kind: 'shell', title: args.title, shell: { command: args.command },
  io: { inputJsonPath: `tasks/${taskCtx.effectId}/input.json`, outputJsonPath: `tasks/${taskCtx.effectId}/output.json` }
}));
export async function process(inputs, ctx) {
  const implementation = await ctx.task(work, { title: 'Implement project corner markers and truthful contextual keys', requirements: inputs.requirements });
  let gate;
  for (let attempt = 1; attempt <= 4; attempt++) {
    gate = await ctx.task(check, { title: 'Verify identity stability, context routing and release build', command: 'swift test && swift build -c release', attempt });
    if (gate.passed) break;
    await ctx.task(work, { title: 'Repair integration failures', failures: gate, attempt });
  }
  if (!gate.passed) throw new Error('Integration gate failed');
  let review;
  for (let attempt = 1; attempt <= 3; attempt++) {
    review = await ctx.task(work, { title: 'Independent review and native visual acceptance', role: 'Independent reviewer', implementation, attempt });
    if (review.passed) break;
    await ctx.task(work, { title: 'Fix review or native acceptance findings', findings: review, attempt });
  }
  if (!review.passed) throw new Error('Review gate failed');
  const delivery = await ctx.task(check, { title: 'Commit, push, package, install and inspect exact release', command: 'scripts/package.sh && scripts/verify.sh && scripts/install.sh' });
  if (!delivery.passed) throw new Error('Delivery gate failed');
  return { success: true, implementation, gate, review, delivery };
}
