type
  SkillMetadata* = object
    name*: string
    description*: string
    requires_tools*: seq[string]

  SkillInfo* = object
    name*: string
    path*: string
    source*: string
    description*: string
    location*: string
    requires_tools*: seq[string]
