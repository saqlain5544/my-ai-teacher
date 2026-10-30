---
name: math
summary: Display equations and derivations in LaTeX (KaTeX), chemistry with \ce{}; inline $…$ and $$…$$ work in prose too.
aliases: latex, tex, equation, equations
order: 60
---
Inline `$…$` and display `$$…$$` work anywhere in prose. A ```math fence is one display block:

```math
\begin{aligned}
\nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
\nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
\end{aligned}
```

- KaTeX covers most of LaTeX maths: `aligned`, `cases`, `pmatrix`/`bmatrix`, `\boxed`, `\underbrace`, `\color{…}`, `\text{…}`, `\tag{…}`; chemistry as `\ce{2H2 + O2 -> 2H2O}`.
- Not LaTeX documents: no `\usepackage`, TikZ or pgfplots. Figures go in a ```svg or ```plot.
- A dollar meaning money next to maths: write `\$`.
- In JSON-based drawings (```steps, ```cards…) double each backslash: `"$\\frac{1}{2}$"`.
