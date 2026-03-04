# Frontier Lab — Worker Instructions

You are a frontier experiment worker. This repo is an isolated sandbox for AI experiments that push the boundaries of what's possible. You write code, run experiments, and document results.

## Experiment Format

Every experiment lives in its own directory under `experiments/`. The directory name format is:
```
YYYY-MM-DD-title-slug
```

### Required Files

Each experiment directory MUST contain:

1. **README.md** — Experiment documentation
```markdown
# [Experiment Title]

## Hypothesis
[What you're testing and why]

## Setup
[What systems/repos this touches, what you read via Agent Teams]

## Approach
[Step-by-step what you did]

## Results
[What happened — data, observations, surprises]

## Verdict
[One of: "Worth pursuing" | "Interesting dead end" | "Needs different approach"]

## Next Steps
[What to try next, or how to promote to a real project task]
```

2. **Code files** — Any scripts, configs, or prototypes created during the experiment

3. **results/** — Output files, logs, screenshots, data from running the experiment

## Rules

- **Read other repos via Agent Teams, write only here** — You can research code in attra, sniffr, seshat, second-brain via Agent Teams. But only write files to this repo.
- **Document everything** — Even failed experiments are valuable. Write what you tried and why it didn't work.
- **Time-boxed** — Each experiment targets 30 minutes of work. Don't over-engineer.
- **Update MEMBRANE.md** — After completing an experiment, add your finding to the membrane map.
- **No production dependencies** — Don't install packages that would affect other repos. Keep experiments self-contained.

## MEMBRANE.md Update Rules

After each experiment, add an entry to MEMBRANE.md:
```markdown
| YYYY-MM-DD | [Title] | [bubble/membrane/outside] | [One-line finding] |
```

Zone classification:
- **bubble** — This is already possible and well-understood. Inside the bubble.
- **membrane** — Uncertain, partially works, or works with caveats. The interesting zone.
- **outside** — Not yet possible or requires capabilities that don't exist yet.

## CALIBRATION.md Update Rules

If the frontier idea had a prediction/hypothesis, log the prediction accuracy:
```markdown
| Date | Prediction | Actual | Score | Notes |
```

Scoring: 1 = spot on, 0.5 = partially right, 0 = wrong

## Do NOT
- Run git commands (handled externally by the spawner)
- Modify files outside the experiments/ directory (except MEMBRANE.md and CALIBRATION.md)
- Make network requests to production services
- Install global packages
