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
    loading*: string         ## SKILL.md `loading:` frontmatter — "lazy" or "always" (default).
                             ## "lazy"  = stub-only by default; full body inlined ONLY when
                             ##           the agent calls `skill action=load name=<skill>`.
                             ##          Sticky for the session until `skill action=unload`.
                             ## "always" (default, also empty) = current behaviour:
                             ##           stub in the catalog, body fetched via read_file
                             ##           on demand, OR inlined automatically when the
                             ##           skill is `channels:`-tagged for the current channel.
                             ## Use lazy for large procedural playbooks the agent
                             ## consults intermittently (e.g. solar-analysis, doc-parse).

  SkillInfo* = object
    name*: string
    path*: string
    source*: string
    description*: string
    location*: string
    requires_tools*: seq[string]
    channels*: seq[string]   ## See SkillMetadata.channels.
    loading*: string         ## See SkillMetadata.loading.
