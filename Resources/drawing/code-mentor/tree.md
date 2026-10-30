---
name: tree
summary: A file tree: folders, files and a note on each.
aliases: filetree, file-tree, folders
order: 150
---
```tree
["myapp/", "  src/", "    main.rs  # entry point: parses the arguments", "    lib.rs  # what the tests use", "  tests/", "    cli.rs", "  Cargo.toml"]
```

Two spaces of indentation per level, a trailing `/` for a folder, `# …` for a note. Plain lines work too, and so does the `tree` command's output.
