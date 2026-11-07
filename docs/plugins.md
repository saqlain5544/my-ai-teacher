# Writing a plugin

A plugin bundles skills, sub-agent types, slash commands, hooks and MCP servers in Claude Code's layout, so one written
for Claude Code usually works as it is. A small working one is in `examples/plugins/study-kit` (one skill, one command).

```
my-plugin/
  .claude-plugin/plugin.json     required
  skills/<name>/SKILL.md         optional: instructions the agent loads when a task needs them
  agents/<name>.md               optional: sub-agent types (front matter name, description, tools, deny, read_only…)
  commands/<name>.md             optional: slash commands (/name)
  hooks/hooks.json               optional: {"hooks": {"PostToolUse": [...]}} in Claude Code's format
  .mcp.json                      optional: {"mcpServers": {...}}
```

`plugin.json`: `name` (lower-case letters, digits, `.`, `_`, `-`; it is the install folder's name), and `version`,
`description`, `author` (a string or `{"name": …}`). Other fields, and custom component paths, are ignored: the folders
above are the only places read.

## What each part does

* **Skills** are `SKILL.md` folders exactly as in Settings › Agents › Skills (`name`, `description`, optional `agents`,
  then the instructions). A skill keeps its name unless the app, you or the open folder already has one by it; then it
  is `plugin:skill`.
* **Commands** are Markdown files. Front matter `description` and `argument-hint`; the body is the message sent.
  `$ARGUMENTS` is everything typed after the command, `$1`…`$9` its words (quotes group). A clash makes it
  `/plugin:command`; a built-in command's name is never taken. **A command file is text only:** Claude Code's `!`
  (run a shell command) and `@` (include a file) are not run, so a command can't act by itself.
* **Agents** are sub-agent types. They work inside the lesson's access like any other: they never get a tool the lesson
  hasn't granted, and a built-in name (`explore`…) can't be taken (yours becomes `plugin-name`).
* **Hooks** are shell commands the user sets to run at steps of the agent's work. They run as the user, with
  `CLAUDE_PLUGIN_ROOT` set to the plugin's folder. The same rules as any hook: a hook can block or add context but an
  `allow` decision never approves a call. Only `command` hooks run.
* **MCP servers** start on first use, as the user. `${CLAUDE_PLUGIN_ROOT}` in `command`, `args`, `env` or `url` is the
  plugin's folder. Their tools are named `mcp__<plugin>-<server>__<tool>`; every call is still asked.

## Installing and trust

**Settings › Plugins** installs from a local folder (copied) or a git URL (`https://`, `ssh://` or `user@host:path`;
shallow clone, no hooks, no submodules, no helper transports, symlinks checked out as plain files, the commit
recorded). Installing uses nothing. The user is shown everything the plugin contains, the hook and MCP commands word
for word, and approves its **fingerprint**: a SHA-256 over every file. Change any file, in an update or on disk, and the
plugin is quiet until it is approved again. Turning a plugin off, or removing it, takes all of it away at once.

Limits: at most 500 files, 20 MB in all, 2 MB a file. A symlink must be relative and stay inside the folder; sockets and
devices are refused; `.git` is not kept. There is no registry and no automatic update: **Update** fetches again from
the recorded source and asks again if anything changed.

## Testing yours

Install the folder, review it, approve it, and type `/` in a lesson: your commands are in the menu, and `/plugin` lists
what is installed. A skill shows as a **Skill** card the first time the agent loads it.
