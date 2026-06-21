"""Apply low-risk list performance optimizations.

This script patches the current Flutter sources without changing app behavior:

1. Wraps each server card in a RepaintBoundary so frequent status updates are
   less likely to repaint neighboring cards.
2. Caps the embedded terminal-window preview inside a server card to a small
   number of visible rows, with a button to open the full terminal-window page.

Run from the repository root:

    python fix_listview.py
"""

from pathlib import Path


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    content = path.read_text(encoding="utf-8")
    if new in content:
        print(f"skip: {description} already applied in {path}")
        return
    if old not in content:
        raise RuntimeError(f"Could not find target block for {description} in {path}")
    path.write_text(content.replace(old, new, 1), encoding="utf-8")
    print(f"patched: {description} in {path}")


def patch_server_cards() -> None:
    path = Path("lib/screens/home/server_list_pane.dart")
    old = """  }) {
    return Selector<SshService, SshConnectionOverview>(
      key: ValueKey(conn.id),
      selector: (_, ssh) => ssh.serverOverviewSnapshot.forConnection(conn.id),
      builder: (context, sessionSummary, _) => _buildConnectionCardBody(
        context,
        conn,
        sessionSummary,
        strings,
        connIndex: connIndex,
      ),
    );
  }
"""
    new = """  }) {
    return RepaintBoundary(
      key: ValueKey('server-card-${conn.id}'),
      child: Selector<SshService, SshConnectionOverview>(
        selector: (_, ssh) => ssh.serverOverviewSnapshot.forConnection(conn.id),
        builder: (context, sessionSummary, _) => _buildConnectionCardBody(
          context,
          conn,
          sessionSummary,
          strings,
          connIndex: connIndex,
        ),
      ),
    );
  }
"""
    replace_once(path, old, new, "server-card repaint boundary")


def patch_embedded_terminal_windows() -> None:
    path = Path("lib/screens/terminal_windows_screen.dart")
    old = """    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            for (var index = 0; index < sessions.length; index++) ...[
              if (index > 0) const SizedBox(height: 8),
              _buildWindowItem(context, viewModel, sessions[index], strings),
            ],
          ],
        ),
      );
    }
"""
    new = """    if (widget.embedded) {
      const previewLimit = 4;
      final visibleSessions = sessions.length > previewLimit
          ? sessions.take(previewLimit).toList(growable: false)
          : sessions;
      final hiddenCount = sessions.length - visibleSessions.length;

      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            for (var index = 0; index < visibleSessions.length; index++) ...[
              if (index > 0) const SizedBox(height: 8),
              _buildWindowItem(
                context,
                viewModel,
                visibleSessions[index],
                strings,
              ),
            ],
            if (hiddenCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_full_rounded, size: 18),
                  label: Text(
                    strings.language == AppLanguage.en
                        ? 'View all ${sessions.length} windows'
                        : '查看全部 ${sessions.length} 个窗口',
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TerminalWindowsScreen(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
"""
    replace_once(path, old, new, "embedded terminal-window preview cap")


def main() -> None:
    patch_server_cards()
    patch_embedded_terminal_windows()


if __name__ == "__main__":
    main()
