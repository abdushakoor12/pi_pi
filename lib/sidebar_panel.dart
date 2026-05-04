import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'pi_rpc_client.dart';
import 'project_manager.dart';
import 'session_manager.dart';

/// A collapsing left-sidebar with two tabs: Projects and History.
///
/// Each project/history entry can be closed (removed) via an X button.
class SidebarPanel extends StatefulWidget {
  final PiRpcClient client;
  final String? gitBranch;
  final bool isGitRepo;

  /// Called when the user picks a project to switch to.
  final ValueChanged<String> onProjectSelected;

  /// Called when the user picks a session to load.
  final ValueChanged<String> onSessionSelected;

  /// Called when a new chat should be started.
  final VoidCallback onNewChat;

  /// Called to cycle the theme.
  final VoidCallback onCycleTheme;

  const SidebarPanel({
    super.key,
    required this.client,
    this.gitBranch,
    required this.isGitRepo,
    required this.onProjectSelected,
    required this.onSessionSelected,
    required this.onNewChat,
    required this.onCycleTheme,
  });

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<String> _projects = [];
  List<SessionSummary> _sessions = [];
  String? _lastCwd;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _lastCwd = widget.client.cwd;
    _loadProjects();
    _loadSessions();
  }

  @override
  void didUpdateWidget(SidebarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.client.cwd != _lastCwd) {
      _lastCwd = widget.client.cwd;
      _loadProjects();
      _loadSessions();
    }
  }

  Future<void> _loadProjects() async {
    final projects = await ProjectManager.getProjects();
    if (mounted) setState(() => _projects = projects);
  }

  Future<void> _loadSessions() async {
    final sessions = await SessionManager.listSessions(widget.client.cwd);
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _addProject() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select a directory to add as project',
      initialDirectory: widget.client.cwd,
    );
    if (picked == null) return;
    await ProjectManager.addProject(picked);
    await _loadProjects();
  }

  Future<void> _removeProject(String path) async {
    await ProjectManager.removeProject(path);
    await _loadProjects();
  }

  String _dirName(String path) {
    try {
      return path.split('/').last;
    } catch (_) {
      return path;
    }
  }

  IconData _iconForPath(String path) {
    if (File('$path/pubspec.yaml').existsSync()) return Icons.flutter_dash;
    if (File('$path/package.json').existsSync()) return Icons.javascript;
    if (Directory('$path/.git').existsSync()) return Icons.code;
    return Icons.folder;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          right: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        children: [
          // ── Sidebar header ────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 1),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  'Pi Pi',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                // New chat
                _SmallIconButton(
                  icon: Icons.add_comment_outlined,
                  tooltip: 'New chat',
                  onPressed: widget.onNewChat,
                ),
                const SizedBox(width: 4),
                // Theme toggle
                _SmallIconButton(
                  icon: theme.brightness == Brightness.dark
                      ? Icons.dark_mode
                      : Icons.light_mode,
                  tooltip: 'Toggle theme',
                  onPressed: widget.onCycleTheme,
                ),
              ],
            ),
          ),

          // ── Current directory info ────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.folder, size: 14, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: widget.client.cwd,
                    child: Text(
                      widget.client.cwd.split('/').last,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (widget.isGitRepo && widget.gitBranch != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.gitBranch!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Tab bar: Projects | History ───────────────────────────
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: cs.primary,
              unselectedLabelColor: cs.onSurfaceVariant,
              indicatorColor: cs.primary,
              indicatorWeight: 2,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 12),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_outlined, size: 14),
                      const SizedBox(width: 4),
                      const Text('Projects'),
                      if (_projects.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_projects.length}',
                            style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.history, size: 14),
                      const SizedBox(width: 4),
                      const Text('History'),
                      if (_sessions.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_sessions.length}',
                            style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Tab content ───────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildProjectsTab(theme, cs),
                _buildHistoryTab(theme, cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Projects tab ────────────────────────────────────────────────────────

  Widget _buildProjectsTab(ThemeData theme, ColorScheme cs) {
    return Column(
      children: [
        if (_projects.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open,
                        size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
                    const SizedBox(height: 12),
                    Text(
                      'No saved projects',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add directories to quickly\nswitch between them',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _projects.length,
              itemBuilder: (context, index) {
                final path = _projects[index];
                final isActive = path == widget.client.cwd;
                return _ProjectItem(
                  path: path,
                  dirName: _dirName(path),
                  icon: _iconForPath(path),
                  isActive: isActive,
                  onSelect: () => widget.onProjectSelected(path),
                  onRemove: () => _removeProject(path),
                );
              },
            ),
          ),
        // ── Add project button ────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: cs.outlineVariant, width: 0.5),
            ),
          ),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addProject,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Project', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 6),
                side: BorderSide(color: cs.outlineVariant),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── History tab ─────────────────────────────────────────────────────────

  Widget _buildHistoryTab(ThemeData theme, ColorScheme cs) {
    if (_sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history,
                  size: 40, color: cs.onSurface.withValues(alpha: 0.2)),
              const SizedBox(height: 12),
              Text(
                'No session history',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Previous chats will appear here',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _sessions.length,
      itemBuilder: (context, index) {
        final s = _sessions[index];
        final date = _formatDate(s.timestamp);
        return _SessionItem(
          title: s.title,
          date: date,
          onSelect: () => widget.onSessionSelected(s.path),
        );
      },
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return 'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      final yesterday = now.subtract(const Duration(days: 1));
      if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        return 'Yesterday ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

// ── Small icon button used in sidebar header ────────────────────────────────

class _SmallIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _SmallIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── Project list item ───────────────────────────────────────────────────────

class _ProjectItem extends StatelessWidget {
  final String path;
  final String dirName;
  final IconData icon;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  const _ProjectItem({
    required this.path,
    required this.dirName,
    required this.icon,
    required this.isActive,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: isActive ? cs.primaryContainer.withValues(alpha: 0.5) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: isActive ? null : onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 16, color: isActive ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dirName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      path,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isActive)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'active',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              // Close/remove button
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  icon: Icon(Icons.close, size: 14),
                  onPressed: onRemove,
                  tooltip: 'Remove project',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant.withValues(alpha: 0.6),
                    hoverColor: cs.error.withValues(alpha: 0.1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Session history list item ───────────────────────────────────────────────

class _SessionItem extends StatelessWidget {
  final String title;
  final String date;
  final VoidCallback onSelect;

  const _SessionItem({
    required this.title,
    required this.date,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      date,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 14, color: cs.onSurface.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}
