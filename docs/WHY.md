# Why review with two providers?

An AI code review is cheap to get and expensive to use. The model returns a list
of findings in the same confident tone whether they are real bugs or
misreadings, so the real cost of a review is the time *you* spend checking each
item. This tool spends more machine time to cut that human time: two models from
different providers review the same code, check each other against the code, and
hand you one list in which every item says how much agreement is behind it.

This page explains why that works, what it costs, especially if you already pay
for both Claude and ChatGPT/Codex, and when a single review is the better choice.

## What a single review gets wrong

- **Confident false positives.** A finding that misreads the code looks exactly
  like one that is right. You cannot tell them apart without checking each one.
- **Blind spots that repeat.** A model misses the same kinds of problems every
  time, because the misses come from how it was trained, not from chance.
  Running it twice, or asking it to "double-check", mostly reproduces the same
  view.
- **Marking its own homework.** Asked to verify its own findings, a model tends to
  agree with itself. Research on LLMs as judges has found that models rate their
  own output more favourably than other models' (self-preference bias).
- **One flat list.** Every item arrives with the same weight. Nothing tells you
  where to start or which items are likely noise.

## What a second, different provider adds

1. **Different blind spots.** Claude and Codex come from different companies,
   trained on different data with different methods. What one misses, the other
   often catches, so their combined findings cover more than either alone.
2. **Verification by a reviewer with no stake in the finding.** In phase 2 each
   model checks the other's findings against the source and must quote the code
   that confirms or refutes each one. A refutation needs evidence; "seems
   unlikely" does not count. This is where most false positives are removed, and
   it is the step a single model cannot do credibly for itself.
3. **A confidence label on every item.** The final report says whether an issue
   was *found by both*, *found by one and confirmed by the other*, or only
   *verified by the arbiter*. Items found by both are the ones to fix first; you
   can trust them more than anything a single review gives you.
4. **Disagreements are shown, not hidden.** When the two still disagree after
   checking the code, the item goes into a "Disputed" section with both
   positions. That is exactly where your attention is worth spending.
5. **Evidence you can check quickly.** Every finding quotes the code and names a
   concrete trigger ("when the list is empty, line 12 divides by zero"), so
   checking one takes seconds instead of a re-read of the file.

## The cost, honestly

One review of one scope is **7 agent calls**: Claude makes 4 (review,
cross-review, meta-review, synthesis) and Codex makes 3. The biggest input is the
source code itself, which is sent four times (phases 1 and 2, to both models).
Compared with a single review of the same code, expect roughly **4 to 5 times the
tokens** and tens of minutes instead of a few. A review where both models find
nothing at MEDIUM or above stops after 2 calls.

### If you already pay for both providers

This is where the approach makes the most sense.

- **The extra cost is quota, not money.** With a Claude subscription that
  includes Claude Code and a ChatGPT plan that includes Codex, a run spends
  allowance you have already paid for. If you mostly work in one of the two, the
  other subscription's quota is largely unused; this puts it to work on
  something it is good at: checking the first one.
- **The work is split across two quotas.** A single-provider review with the
  same amount of checking (review, independent verification, a final pass) would
  take all its calls from one allowance. Here 3 of the 7 calls, and about half of
  the tokens (each model receives the source twice), come from Codex, so you reach your Claude limits later than you would by doing the same work
  with Claude alone.
- **Your time is still the expensive part.** If a review saves you from chasing
  one false positive, or catches one bug before it ships, it has paid for itself
  many times over at subscription prices.

### If you pay per token through the APIs

Then the 4–5× is real money, and the trade is simple: it is worth it when a missed
bug or an hour lost on false alarms costs more than the extra tokens. For
code that matters (data handling, security-relevant paths, anything hard to
change after release) it usually does. For everyday changes it usually does not.

## When a single review is the better choice

- Small diffs and quick sanity checks: use your agent's own review, or this tool
  with `--changed-only` if you still want the cross-check.
- Throwaway or prototype code, and style or readability feedback.
- When you only have access to one provider: a second instance of the same model
  gives you much less than a different one.
- A very large codebase in one go: the models' context fills up. Split it into
  chunks (see the guide), or review only the parts that matter.

## What it does not do

- **It does not run your code.** Every verdict is a model reading code. Two
  models agreeing makes a finding more likely to be real; it is not proof.
- **Claude is also the judge.** The final synthesis is written by Claude, one of
  the two reviewers. The prompts require the same evidence for both sides and the
  report counts rejections per reviewer, so a lopsided split is visible, but the
  conflict of interest is real. The "found by both" label does not depend on the
  judge and is the most reliable signal in the report.
- **No published benchmark yet.** We do not quote accuracy numbers, because we
  have not measured them on a public benchmark. You can measure it yourself in
  ten minutes, below.

## Measure it on your own code

1. Take a small project you know well (or a copy) and plant five to ten bugs of
   the kind you care about: an unchecked empty input, an off-by-one, a missing
   permission check, a resource that is never closed.
2. Ask your usual single agent to review it, and note which planted bugs it finds
   and how many of its other findings are wrong.
3. Run this tool on the same code and note the same two numbers, plus how many of
   its correct findings were marked *found by both*.
4. Compare the two lists by how long it takes you to get to a verified list of
   real bugs, not by length.

If the second list does not save you time on your code, the single review is the
right tool for you.

## Background

The structure (independent answers, then cross-examination, then a judge)
follows work on multi-agent debate for evaluating model outputs, such as
[D3](https://arxiv.org/abs/2410.04663) and [ChatEval](https://github.com/thunlp/ChatEval).
Those papers study evaluation tasks, not code review; this tool borrows the
structure, not their results.
