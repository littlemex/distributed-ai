# Figures

Diagrams for the training-inference mismatch experiments in this directory. Each figure is
a `.drawio` source with a PNG exported at 2x. The `.drawio` is the thing to edit; the PNG
is a build artefact.

Re-export after editing:

```bash
drawio -x -f png -s 2 -o figN_name.png figN_name.drawio
```

| file | what it shows |
|---|---|
| `fig1_arch` | The EKS and KubeRay layout, and the one place two engines must agree on a number but do not |
| `fig2_measurement` | Where the per-token instrumentation hooks in, and why an averaged metric cannot answer a question about sequence position |
| `fig3_tail` | Why a mean gap of 0.03 still destabilises training, and where TIS and veto each intervene on the ratio distribution |
| `fig4_killer` | Six runs to 30 steps, plotted from the recorded series: the metric separates before the reward does |
| `fig5_collapse` | The five stages between a numerical gap and a dead run, with the two that are configuration choices marked |
| `fig6_seeds` | Four seeds per arm on the position slope, and the single-seed interval that had to be withdrawn |
| `fig7_scaling` | The measured variance exponent against the two reference slopes, 1 and 2 |
| `fig8_floor` | Which differences clear the seed-to-seed spread and which are buried inside it |

All numbers in these figures come from runs recorded on p5en.48xlarge (H200) and p5 (H100),
cross-checked between the driver's results file and the trainer's own event files. Figures
4 and 6 through 8 plot per-run values directly rather than summarising them.
