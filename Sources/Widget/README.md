# Widget

Placeholder for the WidgetKit extension target. This directory is excluded
from the app target in `project.yml`; the widget gets its own target and an
App Group container when built (widgets can't read `~/.claude` directly —
the main app writes a summary snapshot the widget reads).
