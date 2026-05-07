type
  SkillMetadata* = object
    name*: string
    description*: string
    requires_tools*: seq[string]
    channels*: seq[string]   ## SKILL.md `channels:` frontmatter list.
                             ## When non-empty, the skill is meaningful
                             ## ONLY when the agent is delivering on one
                             ## of the named channels (e.g. ["feishu"]
                             ## for a Lark Docs / Sheets / Cards skill).
                             ## Empty = channel-agnostic (default).
                             ## The prompt builder uses this to
                             ## highlight skills relevant to the
                             ## current channel and demote / hide
                             ## skills bound to other channels.

  SkillInfo* = object
    name*: string
    path*: string
    source*: string
    description*: string
    location*: string
    requires_tools*: seq[string]
    channels*: seq[string]   ## See SkillMetadata.channels.
