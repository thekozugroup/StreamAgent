/**
 * @process streamagent/native-macos-delivery
 * @description Native UI + hardware integration, composed from desktop-ui-implementation and tdd-quality-convergence patterns.
 * @skill swift-swiftui specializations/mobile-development/skills/swift-swiftui/SKILL.md
 * @agent desktop-ux-analyst specializations/desktop-development/agents/desktop-ux-analyst/AGENT.md
 */
import { defineTask } from '@a5c-ai/babysitter-sdk';

const work = defineTask('streamagent-work', (args, taskCtx) => ({
  kind: 'agent', title: args.title,
  agent: { name: 'general-purpose', prompt: { role: args.role || 'Native macOS engineer', task: args.title, context: args, instructions: ['Perform actual work in repository. Return evidence and changed paths. Do not orchestrate babysitter.'], outputFormat: 'JSON' } },
  io: { inputJsonPath: `tasks/${taskCtx.effectId}/input.json`, outputJsonPath: `tasks/${taskCtx.effectId}/output.json` }
}));
const check = defineTask('streamagent-check', (args, taskCtx) => ({
  kind: 'shell', title: args.title, shell: { command: args.command },
  io: { inputJsonPath: `tasks/${taskCtx.effectId}/input.json`, outputJsonPath: `tasks/${taskCtx.effectId}/output.json` }
}));

export async function process(inputs, ctx) {
  const components = await ctx.parallel.all([
    () => ctx.task(work, { title: 'Direct HID driver and transport tests', component: 'hardware', requirements: inputs.requirements }),
    () => ctx.task(work, { title: 'Read-only live Codex bridge and status tests', component: 'codex', requirements: inputs.requirements }),
    () => ctx.task(work, { title: 'Native app, modules, customization, accessibility', component: 'app', requirements: inputs.requirements })
  ]);
  let verification;
  for (let attempt = 1; attempt <= 4; attempt++) {
    verification = await ctx.task(check, { title: 'Build, test and integration gate', command: 'swift test && swift build -c release', attempt });
    if (verification.passed) break;
    await ctx.task(work, { title: 'Repair concrete integration failures', failures: verification, attempt });
  }
  if (!verification.passed) throw new Error('Integration gate did not pass');
  let review;
  for (let attempt = 1; attempt <= 3; attempt++) {
    review = await ctx.task(work, { title: 'Adversarial product and native/hardware acceptance review', role: 'Independent reviewer', attempt, components });
    if (review.passed) break;
    await ctx.task(work, { title: 'Fix review findings and verify', findings: review, attempt });
  }
  if (!review.passed) throw new Error('Review gate did not pass');
  const delivery = await ctx.task(check, { title: 'Package, launch, document and commit verified app', command: 'scripts/package.sh && scripts/verify.sh' });
  if (!delivery.passed) throw new Error('Delivery gate did not pass');
  return { success: true, components, verification, review, delivery };
}
