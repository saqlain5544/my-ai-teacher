---
name: predict
summary: Predict the output: they read code and write what it prints before seeing it, then compare line by line.
aliases: predict-output, whatprints, prediction
order: 110
---
Run the code first (`run_code`) and put its exact output in `output`: their answer is compared with it line by line.

```predict
{"language": "python", "title": "Two names, one list",
 "code": "xs = [1, 2, 3]\nys = xs\nys.append(4)\nprint(xs)\nprint(len(ys))",
 "output": "[1, 2, 3, 4]\n4",
 "explain": "`ys = xs` copies the reference, not the list: both names see the append."}
```

Fields: `code`, `language`, `output` (exact; required), `explain` (Markdown, shown once they answer or give up), optional `title` and `q` (a question above the code). There is no Run button: they commit to an answer first.
