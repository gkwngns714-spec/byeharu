// WORLD EDITOR — the chrome SHELL pieces of the UX comfort pass: the corner tool rail and the edge
// dock that holds one summoned tool panel. Presentation only: it owns NO editor state, NO draft store,
// NO command, NO fetch. It renders the chrome decided by the pure worldEditorChrome model and hands
// clicks straight back to the shell.
//
// Map-UX law it encodes:
//   #1 clean map      — the dock renders ONLY when a tool is summoned; nothing is parked by default.
//   #2 summon the UI  — the rail is the summon surface; double-click on the map toggles all chrome.
//   #3 corners        — the rail hugs the top-left corner; the dock hugs the right EDGE, never the centre.
//   #4 icons, minimal — the rail is icons with a tooltip; the dock header is one plain word.
//   #6 fold + dismiss — every panel has BOTH "fold back to the rail" and "hide all chrome".
import type { ReactNode } from 'react'
import { Icon } from '../../components/ui'
import {
  WORLD_EDITOR_TOOLS,
  WORLD_EDITOR_TOOL_ICONS,
  WORLD_EDITOR_TOOL_LABELS,
  type WorldEditorChromeState,
  type WorldEditorTool,
} from './worldEditorChrome'

interface RailProps {
  readonly chrome: WorldEditorChromeState
  readonly onToggleTool: (tool: WorldEditorTool) => void
  readonly onDismissAll: () => void
  /** Per-tool attention marks (e.g. unpublished drafts on the Edit tool) — a dot, never a sentence. */
  readonly badges?: Partial<Record<WorldEditorTool, number>>
}

/** The corner tool rail — the ONE summon surface. Icon buttons only; the label rides in the tooltip
 *  and the accessible name. Rendered nothing at all once the owner dismisses the chrome. */
export function WorldEditorToolRail({ chrome, onToggleTool, onDismissAll, badges }: RailProps) {
  if (!chrome.railVisible) return null
  return (
    <div
      className="pointer-events-auto flex flex-col gap-1 rounded-lg border border-edge bg-surface/90 p-1 shadow-overlay backdrop-blur"
      data-testid="worldeditor-tool-rail"
      role="toolbar"
      aria-label="World editor tools"
    >
      {WORLD_EDITOR_TOOLS.map((tool) => {
        const on = chrome.openTool === tool
        const badge = badges?.[tool] ?? 0
        return (
          <button
            key={tool}
            type="button"
            onClick={() => onToggleTool(tool)}
            aria-pressed={on}
            aria-label={WORLD_EDITOR_TOOL_LABELS[tool]}
            title={WORLD_EDITOR_TOOL_LABELS[tool]}
            data-testid={`worldeditor-tool-${tool}`}
            className={`relative flex h-9 w-9 items-center justify-center rounded-md transition ${
              on ? 'bg-accent-soft text-ink' : 'text-ink-muted hover:bg-surface-2 hover:text-ink'
            }`}
          >
            <Icon name={WORLD_EDITOR_TOOL_ICONS[tool]} size={18} />
            {badge > 0 && (
              <span
                className="absolute right-0.5 top-0.5 h-1.5 w-1.5 rounded-full bg-warning"
                aria-hidden="true"
              />
            )}
          </button>
        )
      })}
      <div className="my-0.5 h-px bg-edge" />
      <button
        type="button"
        onClick={onDismissAll}
        aria-label="Hide all panels"
        title="Hide all panels (double-click the map to bring them back)"
        data-testid="worldeditor-chrome-hide"
        className="flex h-9 w-9 items-center justify-center rounded-md text-ink-faint transition hover:bg-surface-2 hover:text-ink"
      >
        <Icon name="close" size={16} />
      </button>
    </div>
  )
}

interface DockProps {
  readonly chrome: WorldEditorChromeState
  readonly onCollapse: () => void
  readonly onDismissAll: () => void
  readonly children: ReactNode
}

/** The edge dock — one summoned tool panel on the RIGHT EDGE, full height, its own scroll. Never
 *  rendered when no tool is open, so the default state is a bare map. */
export function WorldEditorDock({ chrome, onCollapse, onDismissAll, children }: DockProps) {
  if (!chrome.railVisible || chrome.openTool === null) return null
  return (
    <aside
      className="pointer-events-auto absolute inset-y-0 right-0 z-20 flex w-full flex-col border-l border-edge bg-surface/95 shadow-overlay backdrop-blur sm:w-[360px]"
      data-testid="worldeditor-dock"
      aria-label={`${WORLD_EDITOR_TOOL_LABELS[chrome.openTool]} panel`}
    >
      <header className="flex items-center justify-between gap-2 border-b border-edge px-3 py-2">
        <span className="text-sm font-semibold text-ink">{WORLD_EDITOR_TOOL_LABELS[chrome.openTool]}</span>
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={onCollapse}
            aria-label="Fold panel"
            title="Fold panel"
            data-testid="worldeditor-dock-collapse"
            className="flex h-7 w-7 items-center justify-center rounded-md text-ink-muted transition hover:bg-surface-2 hover:text-ink"
          >
            <Icon name="chevron" size={16} />
          </button>
          <button
            type="button"
            onClick={onDismissAll}
            aria-label="Hide all panels"
            title="Hide all panels"
            data-testid="worldeditor-dock-dismiss"
            className="flex h-7 w-7 items-center justify-center rounded-md text-ink-muted transition hover:bg-surface-2 hover:text-ink"
          >
            <Icon name="close" size={16} />
          </button>
        </div>
      </header>
      <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-3">{children}</div>
    </aside>
  )
}
